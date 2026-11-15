# Pocket TTS implementation and local benchmark

Measured on November 12, 2026, on an Apple M1 Pro with 16 GiB RAM,
macOS 27.0 (26A428), ARM64 Dart 3.13.0 and Flutter 3.47.0.

Pocket TTS remains optional. Supertonic 3 is now the default for fresh settings on
supported devices; see [startup changes](supertonic-startup.md). Settings → Narration →
Pocket TTS downloads a SHA-256 verified 163 MB English INT8 bundle and offers
Alba, Marius, Javert, Jean, Fantine, Cosette, Eponine and Azelma. Its saved
voice is independent of existing Kokoro, System and Phonon preferences.
The model reads narration and dialogue in that one voice. Switching back
restores the existing character cast. Pocket does not use LFM3-Audio.

Pocket uses the existing WAV playback, cache, sentence navigation, sleep timer,
volume, punctuation and pause controls. Speed changes affect the player without
reloading the model. Voice changes rebuild the current sentence while retaining
pause state and the sleep timer. Cache identity includes the Pocket voice and
model revision; existing engines' cache identities are unchanged. Optional model
deletion removes only Pocket's store and falls back to Kokoro.

## Results

The prepared-model run, with the engine order reversed from the first run:

| Engine / delegate | Model load | First full clip after load | Warm median full clip | Warm generation speed |
| --- | ---: | ---: | ---: | ---: |
| Kokoro / CPU | 3.26 s | 1.92 s | 2.63 s | 4.53× real time |
| Phonon / CPU | 0.97 s | 0.64 s | 0.78 s | 12.19× real time |
| Pocket TTS / CPU | 1.83 s | 0.98 s | 1.13 s | 7.60× real time |
| Kokoro / GPU vocoder | 5.77 s | 0.66 s | 0.92 s | 11.98× real time |

Model load plus the first full clip was 2.81 seconds for Pocket, 1.60 seconds
for Phonon, 5.17 seconds for CPU Kokoro and 6.43 seconds for GPU-assisted Kokoro.
This measures the speech service, not total app startup or the first Play tap.

The first run measured 4.50×, 12.10×, 7.67× and 14.12× respectively. The CPU
ranking was consistent. GPU Kokoro varied enough that it should not be ranked
above Phonon from this small sample. The first run's Kokoro load included its
initial bundled-model copy; use the prepared-model run for load comparisons.

Pocket is faster than CPU Kokoro on this workload, and offers another voice
family, but it is slower than Phonon and warm GPU-assisted Kokoro. These results
do not justify replacing an existing engine or changing the default.

## Method

`test/tts_benchmark_test.dart` runs the actual app speech wrapper and native
MediaPipe library, not mocked synthesis. It uses mediapipe_audio 0.2.1 / native
1.2.2 and the package's immutable model pins:

- Kokoro: `1ef178b127ec48c737daf17eabb4cea5f6b3ffbc510aced270fe5c267bbeac52`
- Phonon: `b33a9a0d65acec36762db38a2bff6d899f4aab34b196bb56d89fab5665eabebe`
- Pocket: `465e0083cd61188772aed76160b07af0dcf59057497d7659f43f3f2b13a174a1`

Each configuration loads alone, renders one initial clip, then renders the same
four passages in three rounds: descriptive prose, dialogue, names/numbers, and
a longer paragraph. Voices are `af_heart`, `freya` and `alba`. Rate and pause
scale are 1. CPU uses the app's Battery saver delegate choice; GPU Kokoro uses
its normal desktop delegate choice. Each configuration unloads before the next.

Downloads and initial bundle provisioning are excluded. No synthesized clip
cache is used. Warm latency includes PCM conversion and WAV file writing;
decoding for validation is outside the timer. Real-time speed is total generated
audio duration divided by total synthesis time. Full-clip latency is not streaming
time to first audio. Different voices have different output durations.

The harness records finite, non-silent PCM, durations, individual timings,
process RSS, model hashes and platform details. RSS is process-wide and
cumulative, so it cannot establish per-model peak memory or battery use.
The Flutter native test host is ARM64; it is not a release app performance test.
Other apps, filesystem/shader caches, ordering and temperature can affect timings.
No human preference scoring, ASR word-accuracy comparison, long-session battery
test or physical-iPhone benchmark was performed.

## Reproduce and inspect

```sh
flutter test test/tts_benchmark_test.dart \
  --dart-define=RUN_TTS_BENCHMARK=true --reporter expanded

flutter test test/tts_benchmark_test.dart \
  --dart-define=RUN_TTS_BENCHMARK=true \
  --dart-define=BENCH_REVERSE=true --reporter expanded
```

Models are reused under `build/tts-benchmark/models`; normal tests skip this
download-heavy harness. Each run writes `results.json`, `summary.csv` and 52 WAV
clips into a timestamped `build/tts-benchmark` directory. `latest.json` points to
the latest data by containing a copy of its results.

This session's prepared-model artifacts are in:
`build/tts-benchmark/2026-11-12T16-11-19.232148Z/`.
For a listening comparison, use `kokoro_cpu-long_passage-1.wav`,
`phonon_cpu-long_passage-1.wav`, and `pocket_cpu-long_passage-1.wav`.

## Validation

Completed on this Mac: clean `flutter analyze`, 55 passing unit/widget tests
(the two opt-in native harnesses are skipped by the normal suite), the Pocket
native integration check, and both existing listening integration checks.
Both benchmark runs also passed all WAV validation checks (104 clips total).

The focused regressions cover Pocket persistence, valid preset behavior, cache
separation, live voice/rate changes, paused sentence navigation, timer retention,
switching back to the Kokoro cast, small-screen settings and isolated deletion.

```sh
flutter analyze
flutter test
flutter test integration_test/pocket_tts_test.dart -d macos
flutter test integration_test/listening_features_test.dart -d macos
```

The Pocket device check synthesizes all eight voices, then exercises real player
speed/volume, live voice replacement, cached sentence navigation and switching
back to Kokoro. It reuses an installed model or downloads it once. Test clips and
their playback cache are temporary; it does not change saved reading preferences.

## Attribution

Pocket TTS is by Kyutai, with a LiteRT community INT8 conversion, under CC BY 4.0.
Attribution, source links, revision and model checksum are bundled in
`assets/mediapipe/README.txt`. No runtime dependency was added for Pocket.
