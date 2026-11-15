# Supertonic 3 implementation and benchmark

Measured November 13, 2026, on Apple M1 Pro, 16 GiB RAM, ARM64,
macOS 27.0, Flutter 3.47.0 / Dart 3.13.0, Xcode 26.1.1 / Swift 6.2.1.

## Implementation

Supertonic 3 is now the default for fresh settings on supported devices; existing
saved engine/legacy voice selections, voice IDs and book casts are retained.
Settings → Narration exposes ten preset voices and 31
spoken languages. This selects pronunciation/language conditioning, not translation.
Supertonic reads the whole book in one voice. Character casts remain available
when switching back to Kokoro/System, and LFM3-Audio does not override this engine.

The local `native/SupertonicCore` Swift package includes only FluidAudio's
Supertonic pipeline, pinned to source revision
`d653a34a620c013febd7530427b4963ae18064b2`. There is no dependency on the rest of
FluidAudio and no new Flutter runtime package. The shared bridge is registered
for macOS and iOS, with no model loading on the library screen. The iOS
simulator selects CPU compute; devices and Apple-silicon Macs request CPU + ANE.

The model bundle is pinned to `FluidInference/supertonic-3-coreml` revision
`2b5b939dfa1bca362c5212dcafeb8aadde90b1bc`. Its 37 files total 171,674,825 bytes.
They include v2 text/duration models, vocoder, INT4 vector-estimator buckets
128/256/512, ten voice-style JSONs, configuration, indexer and model license.
All buckets are downloaded up front so playback never silently downloads another
model. `assets/supertonic/manifest.json` records each size and SHA-256.

Downloads resume verified files, reject incomplete/corrupt assets and write an
installation receipt only after all files pass. Settings checks completeness;
model loading additionally verifies the hashes. Deletion targets only the
Supertonic revision directory and selects Kokoro if needed.

The engine shares WAV playback, pause scaling, punctuation preparation, cache,
sentence navigation, sleep timer and checkpoints with the existing player. Cache
identity includes its voice, language and model revision. Speed changes use the
player without reinitializing the model. Voice/language changes replace audio
from the current sentence while retaining pause and timer state. Cancellation
is checked between native predictions/chunks, and stale audio is discarded.

The later [startup optimization](supertonic-startup.md) adds native streaming
SHA-256 checks, concurrent Core ML stage loading, a prepared common vector bucket
and selected-voice preparation after a book opens. The historical timings below
precede that work; synthesis weights, compute units and denoising settings are unchanged.

The adapted frontend budgets normalized Unicode scalars, splits overlong words
and rejects encoder overflow instead of silently truncating. This protects long
tokens, accent-heavy words and Korean syllables. It does not prove that the
generative speech model never repeats, mispronounces or omits words.

## Controlled comparison

All engines ran in the same macOS Flutter debug app with the same input passages.
The benchmark holds a scoped `userInitiatedAllowingIdleSystemSleep` activity for
every engine so an invisible test window does not introduce App Nap throttling.
This activity ends with the benchmark and is never enabled by normal playback.

Prepared-model run `2026-11-13T03-13-31.924178Z`:

| Engine / delegate | Model load | First full clip after load | Warm median full clip | Aggregate warm speed |
| --- | ---: | ---: | ---: | ---: |
| Supertonic 3 / CPU + ANE, INT4 | 4.63 s | 0.52 s | 0.30 s | 32.79× real time |
| Kokoro / CPU | 3.20 s | 2.02 s | 2.70 s | 4.28× real time |
| Phonon / CPU | 0.96 s | 0.63 s | 0.77 s | 12.30× real time |
| Pocket TTS / CPU | 1.67 s | 0.90 s | 1.03 s | 7.79× real time |
| Kokoro / GPU vocoder | 3.53 s | 0.70 s | 0.81 s | 14.42× real time |

A second controlled run, `2026-11-13T03-23-35.125248Z`, reversed engine order
and used the final Unicode-budget frontend. Results were consistent:
Supertonic 31.77×, CPU Kokoro 4.03×, Phonon 11.86×, Pocket 7.54× and
GPU-assisted Kokoro 14.36×. Supertonic's warm median was 0.30 s and load plus
first clip was 5.25 s. Both controlled runs passed validation for all 130 WAVs.

Supertonic's first-ever preparation in this session took 8.97 s to load plus
5.77 s for the first clip (14.74 s total). After Core ML's compilation caches
were populated, load plus first clip was 5.15 s. Neither number is an app-startup
or first-Play-tap measurement. Warm speed should not be confused with cold startup.

An earlier unscoped app run showed severe background CPU slowdowns (Kokoro CPU
0.77×, Phonon 2.44×) that disappeared after scoping the user-initiated activity.
That run is excluded from this comparison. The controlled CPU baselines align
with the earlier Pocket benchmark; comparing Supertonic to the throttled values
would exaggerate the improvement.

## Method and limits

The shared harness renders one first clip, then three rounds of the same four
passages: narration, dialogue, names/numbers, and a longer paragraph. There are
12 warm clips per configuration. Voices: Supertonic `M1`, Kokoro `af_heart`,
Phonon `freya`, Pocket `alba`. Phonon uses the current MediaPipe CPU backend;
the optional legacy Core ML/cloned-voice route is unchanged and was not benchmarked.
Rate and pause scale are 1; Supertonic uses eight
denoising steps and 0.05 s inter-chunk silence. One model is loaded at a time.
Downloads/provisioning are excluded; synthesized-clip caching is bypassed.

Latency includes synthesis, PCM conversion and WAV file writing. Validation
decoding is outside the timer. Output must be finite, non-silent PCM. Aggregate
speed is generated audio duration / synthesis wall time; models produce different
durations for the same words. Full-clip latency is not streaming time to first
audio. The current implementation uses complete WAV clips.

Raw JSON records platform, model pins, each passage timing, durations, process RSS
and configuration summaries. RSS is cumulative/process-wide and cannot establish
isolated per-model memory. This is a debug app test, not a release-build or iPhone
performance claim. Other apps, temperature and power conditions remain variables.
There is no ASR accuracy score, human preference study or long-session battery
measurement. Listen to the WAVs before deciding whether this voice suits a book.

## Reproduce

```sh
flutter test integration_test/tts_benchmark_test.dart -d macos \
  --dart-define=RUN_TTS_BENCHMARK=true --reporter expanded

flutter test integration_test/tts_benchmark_test.dart -d macos \
  --dart-define=RUN_TTS_BENCHMARK=true \
  --dart-define=BENCH_REVERSE=true --reporter expanded
```

The app reuses installed models or downloads missing ones. Artifacts are written
under its application-support `benchmarks/all-tts/<timestamp>` directory. This
session's exported JSON, CSV and 65 WAVs per controlled run are under
`build/supertonic-benchmark/<timestamp>`. Compare `*-long_passage-1.wav` for listening.

For a manual model install without starting the app:

```sh
python3 scripts/prepare-reader-supertonic.py --directory /path/to/model-directory
```

Use the revision directory returned by `SupertonicModel.directory()` when
provisioning the app. The script follows the same manifest and verification rules.

## Validation

Completed: clean Flutter analysis, 62 unit/widget tests, three optimized Swift
text-budget tests and four native macOS integration checks (Supertonic, Pocket
and both existing listening checks). Supertonic's check validated every voice,
French/Hindi samples, cancellation/reuse and actual playback controls.

The full iOS Simulator app build was attempted, but Xcode reported no eligible
Runner destination because its iOS 26.1 platform component is not installed.
The local Supertonic package resolves correctly in the iOS dependency graph.
The core was also cross-compiled successfully for ARM64 iOS 18 Simulator, and
the shared Flutter bridge passed iOS Simulator Swift type checking. The full
Runner app build remains unverified because of the missing platform component.
This is not physical-iPhone validation, and no iPhone speed figures are claimed.

Focused regressions cover verified downloads, failed-download recovery, invalid
hashes/paths, isolated deletion, saved voices/languages, presets, cache separation,
paused navigation, live controls, sleep timer retention and the existing cast.
The native Supertonic check synthesizes all ten voices, French and Hindi samples,
cancels running synthesis, verifies subsequent synthesis, and exercises actual
player navigation/settings before switching back to Kokoro.

```sh
flutter analyze
flutter test
swift test -c release --package-path native/SupertonicCore
flutter test integration_test/supertonic_test.dart -d macos
flutter test integration_test/pocket_tts_test.dart -d macos
flutter test integration_test/listening_features_test.dart -d macos
```

## Attribution

[Supertone's model](https://huggingface.co/Supertone/supertonic-3) and its Core ML
conversion retain the BigScience Open RAIL-M license, including use restrictions.
The adapted [FluidAudio code](https://github.com/FluidInference/FluidAudio/tree/d653a34a620c013febd7530427b4963ae18064b2/Sources/FluidAudio/TTS/Supertonic3)
uses Apache 2.0. Both licenses and attribution are bundled in `assets/supertonic`;
source changes are described in `native/SupertonicCore/NOTICE.md`.
