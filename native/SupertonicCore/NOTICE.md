# Supertonic Core

The ten Supertonic3 Swift source files are adapted from FluidInference/FluidAudio,
revision d653a34a620c013febd7530427b4963ae18064b2, under Apache 2.0 (LICENSE).
Source: https://github.com/FluidInference/FluidAudio/tree/d653a34a620c013febd7530427b4963ae18064b2/Sources/FluidAudio/TTS/Supertonic3

Relay Reader changes: local-only model loading; no ModelHub/downloader or other
audio subsystems; local model-name and logging helpers; cooperative cancellation
checks; reject normalized text exceeding the encoder window instead of truncating.
Chunk budgeting counts normalized Unicode scalars and splits overlong words so
Korean, combining marks and unbroken text do not silently lose their endings.
The multi-array reader also accepts future SDK data types through its fallback.
Startup loads independent Core ML stages asynchronously and prepares the common
L128 vector bucket. Model hashes use a local streaming CryptoKit verifier. Model
weights, CPU/ANE configuration and denoising settings are unchanged.
This small local package avoids adding unused ASR/diarization models and runtimes.

Model weights are a separate optional download, converted by FluidInference from
Supertone/supertonic-3. Their BigScience Open RAIL-M license is bundled separately
under assets/supertonic/MODEL-LICENSE.txt. The SDK's Apache license does not replace
the model's use restrictions.
