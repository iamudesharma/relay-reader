import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import 'lfm3.dart';
import 'lfm3_audio.dart';
import 'narration.dart';
import 'phonon.dart';
import 'pocket_tts.dart';
import 'supertonic.dart';
import 'reader_preferences.dart';
import 'theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.preferences,
    required this.theme,
    this.narrator,
    this.aiBusy = false,
  });
  final ReaderPreferences preferences;
  final ReaderThemeController theme;
  final Narrator? narrator;
  final bool aiBusy;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  ReaderPreferences get _preferences => widget.preferences;
  late final Narrator _narrator = widget.narrator ?? Narrator();
  bool get _inUse => _narrator.active || _narrator.navigating || _previewing;
  bool _loading = true, _previewing = false, _loadingSystemVoices = false;

  bool get _lfm3Analyzing => widget.aiBusy;

  bool _phononLoadingVoices = false;
  ({bool active, bool ready, int received, int total}) get _pocket =>
      _preferences.transfers.state('pocket');
  ({bool active, bool ready, int received, int total}) get _supertonic =>
      _preferences.transfers.state('supertonic');
  bool get _lfm3Ready => _preferences.transfers.state('lfm3').ready;
  set _lfm3Ready(bool value) =>
      _preferences.transfers.update('lfm3', ready: value);
  bool get _lfm3AudioReady => _preferences.transfers.state('lfm3Audio').ready;
  set _lfm3AudioReady(bool value) =>
      _preferences.transfers.update('lfm3Audio', ready: value);
  bool get _phononReady => _preferences.transfers.state('phonon').ready;
  set _phononReady(bool value) =>
      _preferences.transfers.update('phonon', ready: value);
  bool get _lfm3Downloading => _preferences.transfers.state('lfm3').active;
  set _lfm3Downloading(bool value) =>
      _preferences.transfers.update('lfm3', active: value);
  int get _lfm3Received => _preferences.transfers.state('lfm3').received;
  set _lfm3Received(int value) =>
      _preferences.transfers.update('lfm3', received: value);
  int get _lfm3Total => _preferences.transfers.state('lfm3').total;
  set _lfm3Total(int value) =>
      _preferences.transfers.update('lfm3', total: value);
  bool get _lfm3AudioDownloading =>
      _preferences.transfers.state('lfm3Audio').active;
  set _lfm3AudioDownloading(bool value) =>
      _preferences.transfers.update('lfm3Audio', active: value);
  int get _lfm3AudioReceived =>
      _preferences.transfers.state('lfm3Audio').received;
  set _lfm3AudioReceived(int value) =>
      _preferences.transfers.update('lfm3Audio', received: value);
  int get _lfm3AudioTotal => _preferences.transfers.state('lfm3Audio').total;
  set _lfm3AudioTotal(int value) =>
      _preferences.transfers.update('lfm3Audio', total: value);
  bool get _phononDownloading => _preferences.transfers.state('phonon').active;
  set _phononDownloading(bool value) =>
      _preferences.transfers.update('phonon', active: value);
  int get _phononReceived => _preferences.transfers.state('phonon').received;
  set _phononReceived(int value) =>
      _preferences.transfers.update('phonon', received: value);
  int get _phononTotal => _preferences.transfers.state('phonon').total;
  set _phononTotal(int value) =>
      _preferences.transfers.update('phonon', total: value);
  List<String> _phononVoices = const [];
  List<SystemVoice> _systemVoices = const [];
  bool get _lfm3Enabled => _preferences.lfm3Enabled;
  set _lfm3Enabled(bool value) => _preferences.lfm3Enabled = value;
  bool get _backgroundPlayback => _preferences.backgroundPlayback;
  set _backgroundPlayback(bool value) =>
      _preferences.backgroundPlayback = value;
  bool get _continueToEnd => _preferences.continueToEnd;
  set _continueToEnd(bool value) => _preferences.continueToEnd = value;

  @override
  void initState() {
    super.initState();
    _preferences.addListener(_refresh);
    _preferences.transfers.addListener(_refresh);
    _narrator.addListener(_refresh);
    unawaited(_initialize());
  }

  void _change(VoidCallback change) {
    if (mounted) {
      setState(change);
    } else {
      change();
    }
  }

  void _refresh() {
    if (mounted) _change(() {});
  }

  Future<void> _initialize() async {
    try {
      await _preferences.load();
      if (!mounted) return;
      _change(() => _loading = false);
      if (!_lfm3AudioDownloading) {
        _lfm3AudioReady = await Lfm3AudioModel.isInstalled();
      }
      if (!_phononDownloading) _phononReady = await PhononModel.isInstalled();
      if (!_pocket.active) {
        _preferences.transfers.update(
          'pocket',
          ready: await PocketTts.isInstalled(),
        );
      }
      if (!_supertonic.active) {
        _preferences.transfers.update(
          'supertonic',
          ready: await SupertonicModel.isInstalled(),
        );
      }
      if (!mounted) return;
      if (SystemVoices.supported) await _loadSystemVoices();
      if (_preferences.lfm3Enabled && !_lfm3Downloading) await _checkLfm3();
      if (!mounted) return;
      if (_preferences.voice.engine == VoiceEngine.phonon && _phononReady) {
        await _loadPhononVoices();
      }
      if (mounted) await _savePreferences();
    } catch (_) {
      if (mounted) _notice('Some settings could not be loaded.');
    } finally {
      if (mounted) _change(() => _loading = false);
    }
  }

  Future<void> _savePreferences() async {
    try {
      await _preferences.save();
    } catch (_) {
      if (mounted) _notice('Settings could not be saved.');
    }
  }

  void _notice(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  void dispose() {
    _preferences.removeListener(_refresh);
    _preferences.transfers.removeListener(_refresh);
    _narrator.removeListener(_refresh);
    if (widget.narrator == null) {
      unawaited(_narrator.close());
    } else {
      unawaited(_narrator.stopPreview());
    }
    super.dispose();
  }

  Future<void> _checkLfm3() async {
    if (!Lfm3Model.supported) return;
    final ready = await Lfm3Model.isDownloaded();
    if (!mounted) return;
    _change(() {
      _lfm3Ready = ready;
      if (!ready) _lfm3Enabled = false;
    });
  }

  Future<void> _toggleLfm3(bool value, {VoidCallback? onUpdate}) async {
    if (_lfm3Downloading || _lfm3Analyzing) return;
    _change(() => _lfm3Enabled = value);
    onUpdate?.call();
    await _savePreferences();
    if (value && !_lfm3Ready) {
      await _checkLfm3();
      if (_lfm3Ready || !mounted) return;
      await _downloadLfm3(onUpdate: onUpdate);
    }
  }

  Future<void> _downloadLfm3({VoidCallback? onUpdate}) async {
    if (_lfm3Downloading || !Lfm3Model.supported) return;
    _change(() {
      _lfm3Downloading = true;
      _lfm3Received = 0;
      _lfm3Total = 100;
    });
    onUpdate?.call();
    try {
      await Lfm3Model.download(
        onProgress: (percent) {
          _change(() => _lfm3Received = percent);
          onUpdate?.call();
        },
      );
      _change(() {
        _lfm3Ready = true;
        _lfm3Enabled = true;
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('LFM3 is ready. Analyze a chapter to try it.');
    } catch (error) {
      _change(() {
        _lfm3Ready = false;
        _lfm3Enabled = false;
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('The LFM3 model could not be downloaded: $error');
    } finally {
      _lfm3Downloading = false;
      onUpdate?.call();
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
      _change(() {
        _lfm3Ready = false;
        _lfm3Enabled = false;
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
    _change(() {
      _preferences.voice = _preferences.voice.withChanges(lfm3Narration: value);
    });
    onUpdate?.call();
    await _savePreferences();
    if (!value && !_narrator.active) unawaited(Lfm3Audio.unload());
  }

  Future<void> _downloadLfm3Audio({VoidCallback? onUpdate}) async {
    if (_lfm3AudioDownloading || !Lfm3AudioModel.supported) return;
    _change(() {
      _lfm3AudioDownloading = true;
      _lfm3AudioReceived = 0;
      _lfm3AudioTotal = Lfm3AudioModel.totalBytes;
    });
    onUpdate?.call();
    try {
      await Lfm3AudioModel.download(
        onProgress: (received, total) {
          _change(() {
            _lfm3AudioReceived = received;
            _lfm3AudioTotal = total;
          });
          onUpdate?.call();
        },
      );
      _change(() {
        _lfm3AudioReady = true;
        _preferences.voice = _preferences.voice.withChanges(
          lfm3Narration: true,
        );
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('LFM3-Audio narration is ready.');
    } catch (error) {
      _change(() {
        _lfm3AudioReady = false;
        _preferences.voice = _preferences.voice.withChanges(
          lfm3Narration: false,
        );
      });
      onUpdate?.call();
      await _savePreferences();
      _notice('The LFM3-Audio model could not be downloaded: $error');
    } finally {
      _lfm3AudioDownloading = false;
      onUpdate?.call();
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
      _change(() {
        _lfm3AudioReady = false;
        _preferences.voice = _preferences.voice.withChanges(
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

  Future<void> _loadSystemVoices() async {
    if (_loadingSystemVoices) return;
    if (mounted) _change(() => _loadingSystemVoices = true);
    try {
      final voices = await SystemVoices.list();
      if (!mounted) return;
      final previous = _preferences.voice;
      _change(() {
        _systemVoices = voices;
        final selected = _preferences.voice;
        if (selected.engine == VoiceEngine.system &&
            !voices.any((voice) => voice.identifier == selected.systemVoice) &&
            voices.isNotEmpty) {
          _preferences.voice = selected.withChanges(
            systemVoice: voices.first.identifier,
          );
        }
      });
      if (!identical(previous, _preferences.voice)) await _savePreferences();
    } finally {
      if (mounted) _change(() => _loadingSystemVoices = false);
    }
  }

  Future<void> _loadPhononVoices() async {
    if (_phononLoadingVoices || !PhononNarration.supported) return;
    _change(() => _phononLoadingVoices = true);
    try {
      final values = await PhononNarration.voices(refresh: true);
      if (!mounted) return;
      final previous = _preferences.voice;
      _change(() {
        _phononVoices = values;
        final selected = _preferences.voice;
        if (selected.engine == VoiceEngine.phonon &&
            values.isNotEmpty &&
            !values.contains(selected.phononVoice)) {
          _preferences.voice = selected.withChanges(phononVoice: values.first);
        }
      });
      if (!identical(previous, _preferences.voice)) await _savePreferences();
    } on PhononException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('The Phonon voices could not be loaded.');
    } finally {
      if (mounted) _change(() => _phononLoadingVoices = false);
    }
  }

  Future<void> _downloadPhonon({VoidCallback? onUpdate}) async {
    if (_phononDownloading) return;
    _change(() {
      _phononDownloading = true;
      _phononReceived = 0;
      _phononTotal = PhononModel.zipBytes;
    });
    onUpdate?.call();
    try {
      await PhononModel.download(
        onProgress: (received, total) {
          _change(() {
            _phononReceived = received;
            _phononTotal = total;
          });
          onUpdate?.call();
        },
      );
      _change(() {
        _phononReady = true;
        _phononDownloading = false;
      });
      if (mounted) await _loadPhononVoices();
      await _savePreferences();
      if (mounted) {
        _notice('Phonon is ready. The experimental narrator is available.');
      }
    } on PhononException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('The Phonon model could not be downloaded.');
    } finally {
      _phononDownloading = false;
      onUpdate?.call();
    }
  }

  Future<void> _importPhononVoice({VoidCallback? onUpdate}) async {
    try {
      const type = XTypeGroup(
        label: 'Phonon voice',
        extensions: ['safetensors'],
      );
      final file = await openFile(acceptedTypeGroups: [type]);
      if (file == null || !mounted) return;
      _change(() {
        _phononDownloading = true;
        _phononReceived = 0;
        _phononTotal = NativePhononModel.zipBytes;
      });
      onUpdate?.call();
      final name = await PhononModel.importVoice(
        File(file.path),
        onProgress: (received, total) {
          _change(() {
            _phononReceived = received;
            _phononTotal = total;
          });
          onUpdate?.call();
        },
      );
      if (mounted) await _loadPhononVoices();
      await _savePreferences();
      if (mounted) {
        _notice('Imported $name. The voice works offline.');
      }
    } on PhononException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('The Phonon voice could not be imported.');
    } finally {
      _phononDownloading = false;
      onUpdate?.call();
    }
  }

  Future<void> _deletePhonon({VoidCallback? onUpdate}) async {
    try {
      await PhononModel.delete();
      _change(() {
        _phononReady = false;
        _phononVoices = const [];
        _phononReceived = 0;
      });
      if (_preferences.voice.engine == VoiceEngine.phonon) {
        _preferences.voice = _preferences.voice.withChanges(
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

  Future<void> _previewVoice(VoiceSettings settings) async {
    _change(() => _previewing = true);
    try {
      await _narrator.preview(settings);
    } on SpeechFailure catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) _notice('The voice preview could not be played.');
    } finally {
      if (mounted) _change(() => _previewing = false);
    }
  }

  Future<void> _downloadPocket() async {
    if (_pocket.active) return;
    _preferences.transfers.update(
      'pocket',
      active: true,
      received: 0,
      total: 163000000,
    );
    try {
      await PocketTts.download((received, total) {
        _preferences.transfers.update(
          'pocket',
          received: received,
          total: total,
        );
      });
      _preferences.transfers.update('pocket', ready: true);
      await _savePreferences();
      _notice('Pocket TTS is ready and works offline.');
    } catch (error) {
      _notice(
        'Pocket TTS could not be downloaded. Check your connection and retry.',
      );
    } finally {
      _preferences.transfers.update('pocket', active: false);
    }
  }

  Future<void> _deletePocket() async {
    if (_pocket.active || _inUse) return;
    _preferences.transfers.update('pocket', active: true);
    try {
      await PocketTts.delete();
      _preferences.transfers.update('pocket', ready: false, received: 0);
      if (_preferences.voice.engine == VoiceEngine.pocket) {
        _preferences.voice = _preferences.voice.withChanges(
          engine: VoiceEngine.kokoro,
        );
        await _savePreferences();
      }
      _notice('The Pocket TTS model was deleted.');
    } catch (_) {
      _notice('The Pocket TTS model could not be deleted.');
    } finally {
      _preferences.transfers.update('pocket', active: false);
    }
  }

  void _selectEngine(VoiceEngine engine) {
    final settings = _preferences.voice;
    final savedVoice = settings.systemVoice;
    final savedIsValid = _systemVoices.any(
      (voice) => voice.identifier == savedVoice,
    );
    _change(() {
      _preferences.voice = settings.withChanges(
        engine: engine,
        systemVoice:
            engine == VoiceEngine.system &&
                _systemVoices.isNotEmpty &&
                !savedIsValid
            ? _systemVoices.first.identifier
            : savedVoice,
        lfm3Narration:
            engine == VoiceEngine.phonon ||
                engine == VoiceEngine.pocket ||
                engine == VoiceEngine.supertonic
            ? false
            : settings.lfm3Narration,
      );
    });
    unawaited(_savePreferences());
    if (engine == VoiceEngine.system && _systemVoices.isEmpty) {
      unawaited(_loadSystemVoices());
    }
    if (engine == VoiceEngine.phonon && _phononReady && _phononVoices.isEmpty) {
      unawaited(_loadPhononVoices());
    }
  }

  Future<void> _downloadSupertonic() async {
    if (_supertonic.active) return;
    _preferences.transfers.update(
      'supertonic',
      active: true,
      received: 0,
      total: 171674825,
    );
    final watch = Stopwatch()..start();
    var last = -100;
    try {
      await SupertonicModel.download((received, total) {
        if (watch.elapsedMilliseconds - last < 80 && received != total) return;
        last = watch.elapsedMilliseconds;
        _preferences.transfers.update(
          'supertonic',
          received: received,
          total: total,
        );
      });
      _preferences.transfers.update('supertonic', ready: true);
      await _savePreferences();
      _notice('Supertonic 3 is ready and works offline.');
    } catch (_) {
      _notice(
        'Supertonic 3 could not be downloaded. Retry to resume verified files.',
      );
    } finally {
      _preferences.transfers.update('supertonic', active: false);
    }
  }

  Future<void> _deleteSupertonic() async {
    if (_supertonic.active || _inUse) return;
    _preferences.transfers.update('supertonic', active: true);
    try {
      await SupertonicModel.delete();
      _preferences.transfers.update('supertonic', ready: false, received: 0);
      if (_preferences.voice.engine == VoiceEngine.supertonic) {
        _preferences.voice = _preferences.voice.withChanges(
          engine: VoiceEngine.kokoro,
        );
        await _savePreferences();
      }
      _notice('The Supertonic 3 model was deleted.');
    } catch (_) {
      _notice('The Supertonic 3 model could not be deleted.');
    } finally {
      _preferences.transfers.update('supertonic', active: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _preferences.voice;
    final system = settings.engine == VoiceEngine.system;
    final phonon = settings.engine == VoiceEngine.phonon;
    final pocket = settings.engine == VoiceEngine.pocket;
    final supertonic = settings.engine == VoiceEngine.supertonic;
    final singleVoice = pocket || supertonic;
    final engines = [
      VoiceEngine.kokoro,
      if (SystemVoices.supported) VoiceEngine.system,
      if (PhononNarration.supported) VoiceEngine.phonon,
      if (PocketTts.supported) VoiceEngine.pocket,
      if (SupertonicModel.supported) VoiceEngine.supertonic,
    ];
    void refreshSheet() {
      if (mounted) _change(() {});
    }

    void update(VoidCallback apply) {
      _change(apply);
      unawaited(_savePreferences());
    }

    Widget page(List<Widget> children) => SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Settings'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Narration'),
              Tab(text: 'Appearance'),
              Tab(text: 'Models'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  page([
                    const Text(
                      'Speed and volume update immediately. Voice and '
                      'narration changes apply from the current sentence.',
                    ),
                    if (engines.length > 1) ...[
                      const SizedBox(height: 16),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth < engines.length * 150) {
                            return Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final engine in engines)
                                  ChoiceChip(
                                    label: Text(engine.label),
                                    selected: settings.engine == engine,
                                    onSelected: (_) => _selectEngine(engine),
                                  ),
                              ],
                            );
                          }
                          return SegmentedButton<VoiceEngine>(
                            segments: [
                              for (final engine in engines)
                                ButtonSegment(
                                  value: engine,
                                  label: Text(engine.label),
                                ),
                            ],
                            selected: {settings.engine},
                            onSelectionChanged: (values) =>
                                _selectEngine(values.first),
                          );
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
                    Text(
                      usesKokoroVoicePresets(settings)
                          ? 'Voice presets'
                          : 'Playback presets',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (!usesKokoroVoicePresets(settings))
                      const Text(
                        'Change the pace while keeping your selected voice.',
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final preset in narrationPresets(settings).entries)
                          ChoiceChip(
                            label: Text(preset.key),
                            selected: isNarrationPresetSelected(
                              settings,
                              preset.value,
                            ),
                            onSelected: (selected) {
                              if (!selected) return;
                              update(
                                () => _preferences.voice = applyNarrationPreset(
                                  settings,
                                  preset.value,
                                ),
                              );
                            },
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
                            () => _preferences.voice = settings.withChanges(
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
                    ] else if (supertonic) ...[
                      const Text(
                        'Default · Supertonic 3 narrator',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'A 172 MB on-device model with ten voices and 31 languages. '
                        'Runs offline after downloading. Supertone · OpenRAIL-M; Core ML conversion by FluidInference.',
                      ),
                      const SizedBox(height: 12),
                      if (_supertonic.active) ...[
                        LinearProgressIndicator(
                          value: _supertonic.total > 0
                              ? (_supertonic.received / _supertonic.total)
                                    .clamp(0, 1)
                              : null,
                        ),
                        Text(
                          '${(_supertonic.received / 1000000).toStringAsFixed(1)} MB downloaded',
                        ),
                      ] else if (!_supertonic.ready)
                        _VoiceNotice(
                          stacked: true,
                          message:
                              'Download Supertonic 3 to use this narrator.',
                          action: 'Download Supertonic 3',
                          onAction: () => unawaited(_downloadSupertonic()),
                        )
                      else ...[
                        DropdownButtonFormField<String>(
                          key: ValueKey(
                            'supertonic-voice-${settings.supertonicVoice}',
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Supertonic voice',
                            border: OutlineInputBorder(),
                          ),
                          initialValue: settings.supertonicVoice,
                          isExpanded: true,
                          items: [
                            for (final voice in SupertonicModel.voices.entries)
                              DropdownMenuItem(
                                value: voice.key,
                                child: Text(voice.value),
                              ),
                          ],
                          onChanged: (value) => update(
                            () => _preferences.voice = settings.withChanges(
                              supertonicVoice: value,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          key: ValueKey(
                            'supertonic-language-${settings.supertonicLanguage}',
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Spoken language',
                            border: OutlineInputBorder(),
                          ),
                          initialValue: settings.supertonicLanguage,
                          isExpanded: true,
                          items: [
                            for (final language
                                in SupertonicModel.languages.entries)
                              DropdownMenuItem(
                                value: language.key,
                                child: Text(language.value),
                              ),
                          ],
                          onChanged: (value) => update(
                            () => _preferences.voice = settings.withChanges(
                              supertonicLanguage: value,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _inUse
                              ? null
                              : () => unawaited(_deleteSupertonic()),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete Supertonic 3 model'),
                        ),
                      ],
                      const SizedBox(height: 6),
                      const Text(
                        'Reads the whole book in your selected voice and language. '
                        'Your saved character cast remains available with Kokoro or System.',
                      ),
                    ] else if (pocket) ...[
                      const Text(
                        'Experimental · Pocket TTS narrator',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'A 163 MB English model with eight voices. '
                        'Works offline after downloading. Kyutai · CC BY 4.0; '
                        'INT8 conversion by the LiteRT community.',
                      ),
                      const SizedBox(height: 12),
                      if (_pocket.active) ...[
                        LinearProgressIndicator(
                          value: _pocket.total > 0
                              ? (_pocket.received / _pocket.total).clamp(0, 1)
                              : null,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${(_pocket.received / 1000000).toStringAsFixed(1)} MB downloaded',
                        ),
                      ] else if (!_pocket.ready)
                        _VoiceNotice(
                          message: 'Download Pocket TTS to use this narrator.',
                          action: 'Download Pocket TTS',
                          onAction: () => unawaited(_downloadPocket()),
                        )
                      else ...[
                        DropdownButtonFormField<String>(
                          key: ValueKey('pocket-${settings.pocketVoice}'),
                          decoration: const InputDecoration(
                            labelText: 'Pocket TTS voice',
                            border: OutlineInputBorder(),
                          ),
                          initialValue: settings.pocketVoice,
                          isExpanded: true,
                          items: [
                            for (final entry in PocketTts.voices.entries)
                              DropdownMenuItem(
                                value: entry.key,
                                child: Text(entry.value),
                              ),
                          ],
                          onChanged: (value) => update(
                            () => _preferences.voice = settings.withChanges(
                              pocketVoice: value,
                            ),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _inUse
                              ? null
                              : () => unawaited(_deletePocket()),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete Pocket TTS model'),
                        ),
                      ],
                      const SizedBox(height: 6),
                      const Text(
                        'Pocket TTS reads the whole book in your selected voice. '
                        'Your saved character cast is available when you switch back to Kokoro or System.',
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
                        'model by Gradium. Built-in voices run locally '
                        'on CPU and work offline after the one-time '
                        'download. License: ${PhononModel.license}.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (_phononDownloading) ...[
                        const SizedBox(height: 10),
                        LinearProgressIndicator(
                          value: _phononTotal > 0
                              ? (_phononReceived / _phononTotal).clamp(0.0, 1.0)
                              : null,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${(_phononTotal > 0 ? _phononReceived / _phononTotal * 100 : 0).clamp(0, 100).round()}% '
                          'of ${(_phononTotal / 1000000).round()} MB',
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
                              onPressed: _inUse
                                  ? null
                                  : () => unawaited(
                                      _deletePhonon(onUpdate: refreshSheet),
                                    ),
                              icon: const Icon(Icons.delete_outline, size: 18),
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
                              _preferences.voice = settings.withChanges(
                                phononVoice: value,
                              );
                            }),
                          ),
                        const SizedBox(height: 6),
                        Text(
                          'Phonon reads the whole book in one voice. '
                          'Character voices and LFM3-Audio are not used '
                          'while it is selected. To use a cloned voice, '
                          'create it in Gradium Studio, download the '
                          '.safetensors file, and import it here. The first '
                          'import also downloads a 137 MB Core ML model.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: _phononDownloading || _inUse
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
                              onPressed: _phononDownloading || _inUse
                                  ? null
                                  : () => unawaited(
                                      _deletePhonon(onUpdate: refreshSheet),
                                    ),
                              icon: const Icon(Icons.delete_outline, size: 18),
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
                          () => _preferences.voice = settings.withChanges(
                            voice: value,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed:
                            _inUse ||
                                pocket && (!_pocket.ready || _pocket.active) ||
                                supertonic &&
                                    (!_supertonic.ready || _supertonic.active)
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
                      subtitle: Text(
                        singleVoice
                            ? '${settings.engine.label} uses one narrator for the whole book.'
                            : 'Use a different voice for quoted dialogue. '
                                  'Manage each book’s cast in Book settings.',
                      ),
                      value: settings.characterVoices,
                      onChanged: singleVoice
                          ? null
                          : (value) => update(() {
                              _preferences.voice = settings.withChanges(
                                characterVoices: value,
                              );
                            }),
                    ),
                    _SettingSlider(
                      label: 'Speed',
                      display: '${settings.speed.toStringAsFixed(2)}×',
                      value: settings.speed,
                      min: .6,
                      max: 1.8,
                      onChanged: (value) => update(
                        () => _preferences.voice = settings.withChanges(
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
                          () => _preferences.voice = settings.withChanges(
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
                          () => _preferences.voice = settings.withChanges(
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
                        _preferences.voice = settings.withChanges(
                          volume: value,
                        );
                      }),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Battery saver'),
                      subtitle: const Text(
                        'Generates less audio ahead and releases idle voices '
                        'sooner. Recommended for long listening sessions on '
                        'iPhone.',
                      ),
                      value: settings.batterySaver,
                      onChanged: (value) => update(() {
                        _preferences.voice = settings.withChanges(
                          batterySaver: value,
                        );
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
                        _preferences.voice = settings.withChanges(
                          punctuation: value
                              ? Punctuation.announce
                              : Punctuation.natural,
                        );
                      }),
                    ),
                  ]),
                  page([
                    ThemeChooser(controller: widget.theme, onChanged: _refresh),
                    const SizedBox(height: 16),
                    _SettingSlider(
                      label: 'Text size',
                      display: '${_preferences.fontSize.round()}',
                      value: _preferences.fontSize,
                      min: 15,
                      max: 34,
                      onChanged: (value) =>
                          update(() => _preferences.fontSize = value),
                    ),
                    _SettingSlider(
                      label: 'Line spacing',
                      display: _preferences.lineHeight.toStringAsFixed(2),
                      value: _preferences.lineHeight,
                      min: 1.25,
                      max: 2,
                      onChanged: (value) =>
                          update(() => _preferences.lineHeight = value),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Darken PDF pages'),
                      subtitle: const Text(
                        'Invert PDF page colors in dark themes.',
                      ),
                      value: _preferences.darkPdfPages,
                      onChanged: (value) =>
                          update(() => _preferences.darkPdfPages = value),
                    ),
                  ]),
                  page([
                    if (Lfm3Model.supported) ...[
                      Text(
                        'Experimental · LFM3 speakers',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Text(
                        'Optional on-device speaker suggestions. Downloads 1.1 GB only when enabled. License: LFM Open License v1.0.',
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Use LFM3 suggestions'),
                        value: _lfm3Enabled,
                        onChanged: _lfm3Downloading || _lfm3Analyzing
                            ? null
                            : (value) => unawaited(
                                _toggleLfm3(value, onUpdate: refreshSheet),
                              ),
                      ),
                      if (_lfm3Downloading) ...[
                        LinearProgressIndicator(value: _lfm3Received / 100),
                        Text(
                          '$_lfm3Received% of ${Lfm3Model.displaySize} (${_lfm3Total > 0 ? 'downloading' : 'preparing'})',
                        ),
                      ],
                      if (!_lfm3Ready)
                        TextButton(
                          onPressed: () async {
                            await _checkLfm3();
                            refreshSheet();
                          },
                          child: const Text('Check downloaded model'),
                        ),
                      if (_lfm3Ready)
                        TextButton.icon(
                          onPressed: _lfm3Analyzing
                              ? null
                              : () => unawaited(
                                  _deleteLfm3(onUpdate: refreshSheet),
                                ),
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete LFM3 model'),
                        ),
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
                                  singleVoice
                                      ? 'Select Kokoro or System to use LFM3-Audio narration'
                                      : _lfm3AudioDownloading
                                      ? 'Downloading the model…'
                                      : _lfm3AudioReady
                                      ? 'Model ready on this device'
                                      : 'Enable or check for a downloaded model',
                                ),
                                value: settings.lfm3Narration,
                                onChanged: _lfm3AudioDownloading || singleVoice
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
                                        _preferences.voice = settings
                                            .withChanges(lfm3Voice: value);
                                      }),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Delete LFM3-Audio model',
                                    onPressed: _lfm3AudioDownloading || _inUse
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
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ] else if (!_lfm3AudioDownloading)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  'Turning this on starts the model '
                                  'download.',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                    ],
                  ]),
                ],
              ),
      ),
    );
  }
}

class _VoiceNotice extends StatelessWidget {
  const _VoiceNotice({
    required this.message,
    required this.action,
    required this.onAction,
    this.stacked = false,
  });

  final String message;
  final String action;
  final VoidCallback onAction;
  final bool stacked;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: stacked
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(message, style: Theme.of(context).textTheme.bodySmall),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: onAction, child: Text(action)),
              ),
            ],
          )
        : Row(
            children: [
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
