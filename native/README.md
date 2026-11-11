# Phonon native runtime

`RelayPhonon.swift` is the Flutter method-channel bridge for the experimental
Phonon narrator. It links `libptts_ffi.a` from the pinned `PhononCore.xcframework`
provided by [`gradium-ai/xn-ptts`](https://github.com/gradium-ai/xn-ptts), release
`v0.7.0`.

The xcframework is not committed. Fetch it once before building:

```sh
scripts/prepare-reader-phonon.sh
```

The 31m English Core ML model is not bundled. The app downloads
`phonon-31m-en-coreml.zip` from the same release only after the reader selects
the experimental engine. The model weights are Apache 2.0; the runtime is
MIT OR Apache-2.0. The app shows the model license in Read aloud settings.
