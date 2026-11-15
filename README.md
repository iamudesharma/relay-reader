# Relay Reader

Relay Reader is a Flutter app for reading and listening to your own books,
completely on-device. Import EPUB, PDF, or plain-text files, read them in a
theme of your choice, and let the app narrate them with local neural voices.
No account, server, or network connection is required after the initial setup.

The app is built for iOS, macOS, and Android. iOS 18+ and macOS 15+ targets use
the same native voice runtimes; the optional Phonon narrator additionally
requires Apple silicon.

## Highlights

- **Local library** — import EPUB, PDF, and UTF-8 TXT files. Each book is kept
  in private app storage, with progress and a single bookmark remembered.
- **Reflowable reading** — eight themes (Auto, Day, Sepia, Slate, Night, Mocha,
  Forest, Ink), adjustable text size and spacing for EPUB/TXT, and full-page
  zoom for PDFs.
- **Offline narration** — Kokoro runs through MediaPipe Audio; System
  uses Apple voices; built-in Phonon voices run through MediaPipe on CPU.
- **Character voices** — detected quoted dialogue can receive distinct cast
  voices, with alias merging, one reserved main character, and a review sheet
  for correcting speakers.
- **Optional local language models** — LFM3 suggests speakers, and
  LFM3-Audio narrates in a 24 kHz voice, both through llama.cpp.
- **Background playback** — continues through locked screens and app switches
  on iOS and Android.

## Requirements

- Flutter 3.47 or newer with Dart 3.13 or newer
- Xcode with iOS 18 / macOS 15 SDKs for Apple builds
- Android SDK for Android builds
- Apple silicon for the experimental Phonon engine

The checked-in iOS and macOS projects target iOS 18 and macOS 15 because the
Phonon Core ML runtime requires them.

## Getting started

The Kokoro and Phonon assets are not committed. Fetch them once before the
first build:

```sh
scripts/prepare-reader-voice.sh
scripts/prepare-reader-phonon.sh

flutter pub get
flutter run -d macos
```

Use `flutter devices` to pick an iOS or Android target. Build a macOS bundle
with `flutter build macos`.

`prepare-reader-voice.sh` resolves dependencies and uses MediaPipe's model
bundler to fetch the SHA-256 pinned Kokoro LiteRT-LM model into
`assets/mediapipe/`. About 295 MB of voice assets ship with the app, so Kokoro
works offline from first use. Models remain outside version control.

`prepare-reader-phonon.sh` prepares the pinned `PhononCore.xcframework`
needed by the existing Apple bridge for cloned voices. The Xcode projects still
link it, so run this script before building for iOS or macOS. Built-in Phonon
voices use MediaPipe and download an approximately 87 MB model only when you
choose Download in settings. Importing a cloned `.safetensors` voice also
fetches the legacy 137 MB Core ML model on its first use. Existing Core ML
installs and saved voices continue to use that bridge.

### Installing a release build on an iPhone

A debug build cannot be launched from the home screen. Install a release build
once, then use the home-screen icon normally:

```sh
scripts/install-reader-iphone.sh
```

The script builds, installs, and launches the app. Set `READER_IPHONE_ID` when
the device identifier changes, `READER_BUNDLE_ID` to override the bundle id, and
`FLUTTER` when `flutter` is not on `PATH`. Rerun it only to install an update;
day-to-day use needs no Flutter, Xcode, or reinstall.

## Read and listen

- **Import a book** opens an EPUB, PDF, or UTF-8 TXT file directly in the reader
  and stores a private local copy in the library. Imports are limited to 200 MB
  for PDF and EPUB, and 8 MB for TXT. If a book cannot be opened, the app shows
  the specific reason and offers to copy the technical details. Malformed EPUBs
  without a declared spine are still read in manifest order, and damaged
  packages are recovered in text-only mode when their chapters are readable.
  DRM-locked books are identified and left untouched.
- **Reading theme** is available from the library palette and from any open
  book. EPUB and TXT reflow with adjustable text size and spacing. Swipe
  sideways through PDF pages, one whole page at a time; pinch or double-tap to
  zoom, and double-tap again to fit the page. Dark themes can invert PDF page
  colors.
- The app remembers the current chapter or page and one bookmark per book.
  Narration saves the exact sentence being spoken as well, so **Continue
  listening** resumes from that point after closing the app. The library shows
  the most recent listening position with a resume button.
- **Character voices** give quoted dialogue its own cast. The cast is saved per
  book and can be edited in **Book settings → Cast**. Choose one **main
  character**; their voice is reserved and can never be taken by a side
  character. Alias merging (Elizabeth / Lizzy / Miss Bennet) keeps one identity
  and one voice. Detection runs offline using dialogue tags, scene context, and
  turn-taking; it is approximate, so every character voice can be changed or
  removed. **Review speakers in this chapter** shows each quoted line and lets
  you correct its speaker. Corrections and automatic results are cached per
  section.
- **Pocket TTS** is an optional English narrator in **Settings → Narration**.
  Select Pocket TTS and download its 163 MB model once; its eight voices then
  work offline on iOS and macOS. It reads the whole book in one selected voice,
  retaining the Kokoro/System cast for switching back. Voice, speed, volume,
  sentence navigation, sleep timer and cached clips use the existing playback
  controls. Deleting Pocket removes only its model and selects Kokoro. Kyutai's
  weights use CC BY 4.0; attribution is bundled in `assets/mediapipe/README.txt`.
  Benchmark with `flutter test test/tts_benchmark_test.dart
  --dart-define=RUN_TTS_BENCHMARK=true --reporter expanded`; this downloads the
  optional models into `build/tts-benchmark/models` and writes JSON, CSV and
  WAV samples under `build/tts-benchmark`. See `docs/pocket-tts-benchmark.md`.
- **Experimental LFM3 speakers** is optional. Turn it on only if you want to try
  a local 1.1 GB LFM3 model: the model is downloaded at that moment, never
  bundled or fetched before. It runs through Flutter Edge AI and llama.cpp on
  macOS 15+ and iOS 18+, with no cloud calls. **Analyze this chapter** produces
  paragraph-level speaker suggestions in the review sheet; they are cached,
  marked **LFM3**, and never replace lines you edited manually. The model can be
  slow and inaccurate, so treat it as a suggestion engine and review its output.
- **Supertonic 3** is the default narrator for fresh settings on macOS 15+ and
  iOS 18+. Saved engine selections and legacy Kokoro voice choices are preserved.
  Select it in **Settings → Narration**. Its separately downloaded 172 MB Core ML bundle has ten
  voices and 31 spoken languages, including English and Hindi. Choose the language
  of your book; this does not translate its text. It reads narration and dialogue
  in one selected voice, while retaining your Kokoro/System cast. Speed and volume
  update live; voice/language changes apply from the current sentence. The first
  use prepares the Core ML models and takes longer than warm playback. Weights
  use OpenRAIL-M; the license and attribution are bundled under `assets/supertonic`.
  Until it is downloaded, the reader offers Settings and keeps bundled Kokoro
  available offline. Opening a book prepares the selected, installed Supertonic
  voice after the first frame, without playing audio. Other engines stay available.
  See [implementation and benchmark](docs/supertonic-3-benchmark.md) and
  [startup measurements](docs/supertonic-startup.md).
- **Experimental LFM3-Audio narrator** is optional. Turning it on downloads a
  local 1.3 GB LFM3-Audio-2B Q4_K_M model plus its audio projector. It reads
  narration with a 24 kHz voice on macOS 15+ and iOS 18+ while quoted dialogue
  keeps the Kokoro or System cast voices. It offers female and male voices only,
  so it is deliberately limited to narration; turn off Character voices to have
  it read the whole book. The model is slow and still experimental. Use
  **Delete LFM3-Audio model** to reclaim its disk space.
- Remove a book through its library menu to delete the imported copy, cast,
  listening checkpoint, and cached speaker results. Use **Delete LFM3 model** in
  the same settings section to reclaim its disk space.
- **Read aloud** starts at the current chapter or page and advances through the
  book. The sentence currently being spoken is highlighted in TXT and EPUB
  pages, and the **Now playing** bar shows the passage and speaker. For EPUB,
  the paragraph containing the sentence is highlighted. PDF pages show the
  now-playing bar without text highlighting. On iOS and Android, **Background
  playback** keeps the queue running while the screen is locked or another app
  is open, and **Continue through the book** automatically starts the next
  chapter or page. Pause, resume, and stop controls are available in the app.

- **Previous/next sentence** controls appear while listening. They keep the
  current cast voice, text highlight, saved position, and pause state in sync;
  navigation crosses empty chapters when continuing through the book.
- **Sleep timer** offers 15, 30, or 60 minutes, or the end of the current chapter
  or page. The duration includes time spent paused. Manual Stop, closing the
  reader, and finishing the book clear the timer; sentence navigation retains
  it. The timer menu and countdown sit alongside the sentence controls.
- **Reusable narration audio** is kept in a disposable cache capped at 200 MiB.
  Revisiting a passage reuses its audio when the book, text, voice, and synthesis
  settings match. Old clips are evicted automatically; removing a book removes
  its cached audio. Disk/cache failures fall back to ordinary synthesis.
- **Deferred optional AI** lets the library launch without waiting for Edge AI.
  The runtime initializes when LFM3 is enabled or its installed model is checked,
  downloaded, used, or deleted. Previously enabled LFM3 preferences still work.

App-wide preferences are in **Settings**, available from both the library and
an open book. Its **Narration**, **Appearance**, and **Models** tabs contain
voice/playback options, reading theme/text layout/PDF colors, and experimental
model management. Changes are saved as you make them and apply across books.
Model downloads retain their progress when Settings is closed and reopened.
**Book settings** contains only the current book's cast, main character, speaker
corrections, and chapter speaker analysis. Existing preferences and book data
are retained.

## Narration engines

**Settings → Narration** offers 28 US and UK English Kokoro voices with tone
labels, Warm/Natural/Clear/Bright/British/Fast presets, a voice preview, and
controls for speed, sentence pauses, volume, and spoken punctuation. Preset
chips show the active choice. Phonon, System, and LFM3-Audio offer
Relaxed/Natural/Fast playback presets that retain the selected voice.

| Engine | Runs on | Model | Notes |
| --- | --- | --- | --- |
| Supertonic 3 (default on supported devices) | Core ML CPU + ANE | Download once, ~172 MB | 10 voices, 31 languages |
| Kokoro (bundled fallback) | MediaPipe CPU; Metal vocoder on supported Macs | Bundled, ~295 MB | 28 English voices, character cast, battery saver |
| System | Apple speech | OS voices | Uses enhanced/premium voices downloaded in system settings |
| Phonon (experimental) | MediaPipe CPU; Core ML for legacy/cloned voices | 87 MB, downloaded on demand | Built-in voices; cloned voices retain the native runtime |
| LFM3-Audio (experimental) | llama.cpp | 1.3 GB, downloaded on demand | Narration only, female/male voices |

On iPhone, switch the engine to **System** to use Apple voices, including
enhanced and premium voices downloaded in Settings › Accessibility › Spoken
Content › Voices.

**Phonon** runs Gradium's 31m model and works offline after the model
download. It reads the whole book in one voice; character voices and
LFM3-Audio are not used while it is selected. Custom Phonon voices can be
created in Gradium Studio and imported as `.safetensors` files; the app does not
enrol a recording on-device.

**Battery saver** keeps Kokoro on CPU and uses a smaller audio
buffer; it is on by default on iOS and Android. Narration stops generating new
clips while paused, and the Kokoro model is unloaded after a short idle period.
Speed and volume change during playback immediately. Voice, engine, tone,
punctuation and pause changes regenerate audio from the current sentence while
preserving pause state, listening position, and the sleep timer.

## Offline and privacy

Books, settings, progress, and cached speaker results live in the app's private
storage. Audio is synthesized into temporary clips and removed after playback.
Nothing is uploaded. After the initial asset setup and any optional model
downloads, importing, reading, and narration work without a connection.

PDF narration requires an embedded text layer. Scanned pages can be viewed but
not narrated. Import supports unencrypted EPUB and PDF files.

## Project layout

```text
lib/                 App, library, reader, narration, engines, themes
ios/ macos/ android/ Platform projects and the Phonon Swift bridge
native/              Phonon C header, module map, and Swift bridge
assets/              Kokoro assets (downloaded) and branding
integration_test/    On-device integration tests
test/                Widget and unit tests
tool/                App icon generators
scripts/             Asset setup and release install helpers
docs/                Narration coverage research
```

## App icon

The icon is drawn without external image assets: `tool/generate_app_icon.swift`
writes the full-bleed 1024 px master, then `tool/generate_app_icon.py`
distributes opaque iOS and macOS icons and rounded Android launcher icons. The
macOS asset catalog art stays full-bleed and opaque so macOS 26 adds its own
squircle and glass treatment instead of a gray legacy plate. The Python step
needs Pillow:

```sh
swift tool/generate_app_icon.swift
python3 tool/generate_app_icon.py
```

## Validate

```sh
flutter analyze
flutter test
flutter test integration_test/local_reader_test.dart -d macos
flutter test integration_test/lfm3_audio_test.dart -d macos
flutter test integration_test/phonon_settings_test.dart -d macos
```

The native integration tests require the staged voice assets. The LFM3-Audio
test also expects the model and projector under the app's private
`lfm3_audio` directory; download them through the app's experimental narration
setting before running it. The Phonon test expects its model to be installed.

## Third-party components

Kokoro, Phonon, LFM3, MediaPipe Audio, llama.cpp, and the Flutter plugins are used
under their respective licenses; see `native/README.md` and the license files
shipped with each model. Model weights are not committed to this repository.

## MediaPipe TTS validation

`mediapipe_audio` is pinned to 0.2.1. Saved Kokoro speaker numbers map to the
same 28 US/UK voice names; a bundle missing any of them is rejected. Synthesis
is serialized on warm tasks, cancellation invalidates pending loads and clips,
and idle tasks release their native memory. Audio is converted to PCM16 WAV
for the existing background playback queue. Sentence pause settings scale
sustained internal silence in the generated waveform; they are an approximation
of the previous runtime's native silence control. Speed is configured at task
creation and changing it reloads the task.

The pinned Kokoro bundle has a GPU vocoder. The package currently exposes this
only on supported Apple-silicon Macs; battery saver and other targets use CPU.
The model card warns that CPU output from this bundle can be noisier. Physical
phone quality, memory, battery use, background playback and thermal performance
must be checked before shipping; no speed or quality improvement is assumed.

Run the ordinary checks with `flutter analyze` and `flutter test`. To exercise
the actual native library and write listening samples to
`build/mediapipe-samples/`, run:

```sh
flutter test test/mediapipe_native_test.dart --dart-define=RUN_MEDIAPIPE_NATIVE=true
```

That test downloads Phonon into a disposable test directory, exercises US/UK
Kokoro voices and Phonon, then deletes the test model cache. The ordinary suite
skips this model-dependent check. Flutter Edge AI and llama.cpp remain because
the optional LFM3 speaker analysis and LFM3-Audio features still use them.

The listening feature regressions run in `flutter test`. To check native audio
playback, paused sentence navigation, the chapter-end timer, and active controls
in phone portrait/landscape layouts on macOS, run:

```sh
flutter test integration_test/listening_features_test.dart -d macos
```

This uses disposable audio and model-free test synthesis. Physical iPhone
background playback and battery measurements remain separate device checks.
