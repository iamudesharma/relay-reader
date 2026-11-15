# Default narrator and startup optimization

Measured November 13, 2026, on the same M1 Pro / 16 GiB Mac as the earlier TTS
comparison. Measurements use the macOS Flutter debug app with App Nap inhibited,
the same voice/text/model files, no synthesized-clip cache and existing Core ML
device-specialization caches. These are model-cold reloads, not first-ever installs.

## Behavior

Fresh preferences select Supertonic 3 on supported macOS 15+ / iOS 18+ devices.
Explicit saved engine selections, legacy voice-only Kokoro preferences, book casts,
checkpoints and listening controls are preserved. Other engines remain selectable.
Unsupported devices and invalid saved engine identifiers retain Kokoro fallback.

The model remains a separate one-time download. Until it is installed, Read aloud
uses bundled Kokoro with a Settings action explaining how to download the default
narrator. Preference loading and the library do not download or initialize models.

After a book is visible, the reader prepares only its selected installed Supertonic
voice. Preparation is shared across overlapping requests, generates no speech,
starts no player and changes no checkpoint, pause state or timer. Leaving/stopping
the reader cancels and drains preparation. Idle model retention follows the
existing 30-second Battery saver / 90-second normal policy. Preparation errors do
not interrupt visual reading; Read aloud reports a model failure normally.

## Changes and profiling

Profiling separated bundle verification, each Core ML model load and first
synthesis. The largest avoidable cost was pure-Dart SHA-256: approximately
1.7–1.9 seconds for the 172 MB bundle on each reload. The text encoder's Neural
Engine loading itself still takes about 2.6 seconds.

- Native streaming CryptoKit SHA-256 performs the same full file/hash checks in
  about 0.11–0.15 seconds, off Flutter's UI isolate. Nothing skips verification.
- Independent text/duration/vocoder/vector models load concurrently through
  `MLModel.load(contentsOf:configuration:)`. The common L128 vector bucket is
  ready before first synthesis; larger buckets remain lazy.
- File locations remain stable so Core ML's specialization caches remain useful.
- Model weights, precision, CPU/ANE routing, eight denoising steps, rate and pause
  handling are unchanged. Existing audio-cache identities remain valid.

## Results

Three reloads per variant; median values:

| Measurement | Before | After |
| --- | ---: | ---: |
| Full bundle verification | 1.78 s | 0.11 s |
| Load / preparation | 4.51 s | 2.71 s |
| Preparation plus first full clip | 4.88 s | 3.01 s |
| Warm switch to F2, short passage | 0.106 s | 0.104 s |

Preparation plus first clip improved by approximately **38%**. Independent
model load durations overlap after the change and must not be summed.

The reader integration check then opened a book using fresh default preferences,
waited for preparation without starting playback, and pressed Read aloud. It
reached the playing state in **0.962 seconds** in that single check. This includes
reader/player setup and is separate from synthesis-only timing; it is not a
guaranteed latency across devices.

The earlier first-ever 14.74-second specialization measurement was not repeated
by deleting OS caches. First-install download/compilation cost still exists.
No iPhone startup or battery claim is made. Full iOS app validation previously
hit a missing Xcode platform component; core/bridge compilation is checked separately.

## Artifacts and reproduction

```sh
flutter test integration_test/supertonic_startup_test.dart -d macos \
  --dart-define=STARTUP_VARIANT=optimized --reporter expanded
```

The harness writes stage timings and WAVs under application support:
`benchmarks/supertonic-startup/<variant>-<timestamp>/`.
Exported session artifacts are in `build/supertonic-startup/`, including:

- `baseline-2026-11-13T03-46-27.246422Z/results.json`
- `optimized-final-2026-11-13T04-01-08.939694Z/results.json`
- `prepared-play.json`

Validation: clean Flutter analysis, 67 unit/widget checks, four Swift tests and
six native macOS checks across the startup, Supertonic, Pocket and listening
targets. Coverage includes preference migration/defaults, download verification
and corruption detection, coalesced preparation/cancellation, all native voices,
French/Hindi, audio navigation/caching, live settings and the sleep timer. The
iOS 18 ARM64 simulator core module builds and the Flutter bridge typechecks;
the full iOS app remains unvalidated because Xcode lacks its iOS platform component.

Supertonic device-test attempts were interrupted after stalling while waiting
for Flutter frames in a test that renders no UI. Those native-only checks now
wait on the real clock instead. The listening UI check also stopped advancing in
the background and resumed when the test app was activated. The device checks
now hold the same scoped process activity as the timing harness; the listening
target completed in nine seconds
without foreground assistance, and the corrected Supertonic target completed in
14 seconds. Normal reader power behavior is unchanged. The Kokoro dropdown
regression explicitly selects Kokoro instead of assuming it is the default.
