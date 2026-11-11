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
- **Offline narration** — Kokoro int8 runs on CPU through sherpa-onnx; System
  uses Apple voices; Phonon runs on the Apple Neural Engine.
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

`prepare-reader-voice.sh` stages the Kokoro v1.0 int8 model and two English
pronunciation dictionaries under `assets/kokoro-v1/`. The app bundles roughly
150 MB of voice assets and copies them into its private data directory the first
time you use Read aloud. You can skip this script if you only want the visual
reader.

`prepare-reader-phonon.sh` downloads the pinned `PhononCore.xcframework`
(about 52 MB compressed, 192 MB extracted) used by the experimental Phonon
narrator. It is a build-time dependency; the 137 MB Phonon 31m Core ML model is
downloaded at runtime only after you select that engine. The checked-in Xcode
projects link `native/PhononCore.xcframework`, so run the script before building
the iOS or macOS app.

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
  book and can be edited in **Read aloud settings → Cast**. Choose one **main
  character**; their voice is reserved and can never be taken by a side
  character. Alias merging (Elizabeth / Lizzy / Miss Bennet) keeps one identity
  and one voice. Detection runs offline using dialogue tags, scene context, and
  turn-taking; it is approximate, so every character voice can be changed or
  removed. **Review speakers in this chapter** shows each quoted line and lets
  you correct its speaker. Corrections and automatic results are cached per
  section.
- **Experimental LFM3 speakers** is optional. Turn it on only if you want to try
  a local 1.1 GB LFM3 model: the model is downloaded at that moment, never
  bundled or fetched before. It runs through Flutter Edge AI and llama.cpp on
  macOS 15+ and iOS 18+, with no cloud calls. **Analyze this chapter** produces
  paragraph-level speaker suggestions in the review sheet; they are cached,
  marked **LFM3**, and never replace lines you edited manually. The model can be
  slow and inaccurate, so treat it as a suggestion engine and review its output.
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

## Narration engines

**Read aloud settings** offers 28 US and UK English Kokoro voices with tone
labels, Warm/Natural/Clear/Bright/British/Fast presets, a voice preview, and
controls for speed, sentence pauses, volume, and spoken punctuation.

| Engine | Runs on | Model | Notes |
| --- | --- | --- | --- |
| Kokoro (default) | CPU, sherpa-onnx | Bundled, ~150 MB | 28 English voices, character cast, battery saver |
| System | Apple speech | OS voices | Uses enhanced/premium voices downloaded in system settings |
| Phonon (experimental) | Apple Neural Engine, Core ML | 137 MB, downloaded on demand | English only, one narrator voice, cloned voices via import |
| LFM3-Audio (experimental) | llama.cpp | 1.3 GB, downloaded on demand | Narration only, female/male voices |

On iPhone, switch the engine to **System** to use Apple voices, including
enhanced and premium voices downloaded in Settings › Accessibility › Spoken
Content › Voices.

**Phonon** runs Gradium's 31m Core ML model and works offline after the model
download. It reads the whole book in one voice; character voices and
LFM3-Audio are not used while it is selected. Custom Phonon voices can be
created in Gradium Studio and imported as `.safetensors` files; the app does not
enrol a recording on-device.

**Battery saver** reduces Kokoro to two CPU threads and keeps a smaller audio
buffer; it is on by default on iOS and Android. Narration stops generating new
clips while paused, and the Kokoro model is unloaded after a short idle period.
Volume changes immediately; other narration changes apply the next time you
start Read aloud.

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

Kokoro, Phonon, LFM3, sherpa-onnx, llama.cpp, and the Flutter plugins are used
under their respective licenses; see `native/README.md` and the license files
shipped with each model. Model weights are not committed to this repository.
