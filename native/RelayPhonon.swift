import AVFoundation
import Foundation
import PhononCore

#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Native bridge for the experimental Phonon narrator.
///
/// The Core ML bundle is downloaded by Dart and passed to this bridge as a
/// writable folder. All model calls are serialized on one queue because the
/// Phonon C runtime is not reentrant.
final class RelayPhonon {
  static let shared = RelayPhonon()
  static let channelName = "relay_reader/phonon"

  private let queue = DispatchQueue(label: "relay-reader.phonon", qos: .userInitiated)
  private var handle: OpaquePointer?
  private var loadedPath: String?
  private var voices: [String] = []

  private init() {}

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(
          FlutterError(
            code: "unavailable",
            message: "The Phonon engine is unavailable.",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "status":
        result(self.status())
      case "load":
        self.load(call.arguments, result: result)
      case "synthesize":
        self.synthesize(call.arguments, result: result)
      case "unload":
        self.unload(result: result)
      case "stopPreview":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private var available: Bool {
    if #available(iOS 18.0, macOS 15.0, *) { return true }
    return false
  }

  private func status() -> [String: Any] {
    var value: [String: Any] = [
      "available": available,
      "loaded": handle != nil,
    ]
    if let loadedPath { value["modelPath"] = loadedPath }
    if !voices.isEmpty { value["voices"] = voices }
    return value
  }

  private func load(_ arguments: Any?, result: @escaping FlutterResult) {
    guard available else {
      result(
        FlutterError(
          code: "unsupported_os",
          message: "Phonon requires iOS 18 or macOS 15 on Apple silicon.",
          details: nil
        )
      )
      return
    }
    guard let args = arguments as? [String: Any],
          let path = args["path"] as? String,
          !path.isEmpty else {
      result(
        FlutterError(
          code: "bad_arguments",
          message: "A Phonon model folder is required.",
          details: nil
        )
      )
      return
    }

    queue.async {
      if self.handle != nil && self.loadedPath == path {
        result(self.voices)
        return
      }
      self.freeHandle()
      var newHandle: OpaquePointer?
      let failure: String? = path.withCString { directory in
        "en".withCString { language in
          newHandle = ptts_new(directory, UInt32(PTTS_UNIT_ANE), language)
          // The simulator has no Neural Engine. Fall back to the CPU rather
          // than hiding the experiment on a development machine.
          if newHandle == nil {
            newHandle = ptts_new(directory, UInt32(PTTS_UNIT_CPU), language)
          }
          guard newHandle == nil else { return nil }
          return Self.lastError(nil) ?? "Phonon could not load this model."
        }
      }
      if let failure {
        result(
          FlutterError(
            code: "load_failed",
            message: failure,
            details: nil
          )
        )
        return
      }
      self.handle = newHandle
      self.loadedPath = path
      self.voices = Self.names(ptts_voices(newHandle))
      result(self.voices)
    }
  }

  private func synthesize(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let text = args["text"] as? String,
          !text.isEmpty,
          let path = args["path"] as? String,
          !path.isEmpty else {
      result(
        FlutterError(
          code: "bad_arguments",
          message: "Speech needs text and an output path.",
          details: nil
        )
      )
      return
    }

    queue.async {
      guard let handle = self.handle else {
        result(
          FlutterError(
            code: "not_loaded",
            message: "Load the Phonon model before narrating.",
            details: nil
          )
        )
        return
      }
      if let voice = args["voice"] as? String, !voice.isEmpty {
        _ = voice.withCString { ptts_set_voice(handle, $0) }
      }

      let buffer = SynthesisBuffer()
      buffer.samples.reserveCapacity(24_000 * 20)
      let user = Unmanaged.passUnretained(buffer).toOpaque()
      var stats = PttsResult()
      let ok = text.withCString { phrase in
        ptts_speak(handle, phrase, phononFrame, user, &stats)
      }
      guard ok else {
        let message = Self.lastError(handle) ?? "Phonon could not narrate this passage."
        result(
          FlutterError(
            code: "synthesis_failed",
            message: message,
            details: nil
          )
        )
        return
      }
      guard !buffer.samples.isEmpty else {
        result(
          FlutterError(
            code: "empty_audio",
            message: "Phonon returned no audio for this passage.",
            details: nil
          )
        )
        return
      }
      do {
        try Self.writeWav(buffer.samples, to: path)
        result(nil)
      } catch {
        result(
          FlutterError(
            code: "write_failed",
            message: "The Phonon audio could not be saved: \(error)",
            details: nil
          )
        )
      }
    }
  }

  private func unload(result: @escaping FlutterResult) {
    queue.async {
      self.freeHandle()
      self.loadedPath = nil
      self.voices = []
      result(nil)
    }
  }

  private func freeHandle() {
    if let handle { ptts_free(handle) }
    handle = nil
  }

  private static func names(_ block: UnsafePointer<CChar>?) -> [String] {
    var values: [String] = []
    guard var pointer = block else { return values }
    while true {
      let name = String(cString: pointer)
      if name.isEmpty { break }
      values.append(name)
      pointer = pointer.advanced(by: name.utf8.count + 1)
    }
    return values
  }

  private static func lastError(_ handle: OpaquePointer?) -> String? {
    guard let pointer = ptts_last_error(handle) else { return nil }
    let message = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
    return message.isEmpty ? nil : message
  }

  private static func writeWav(_ samples: [Float], to path: String) throws {
    let dataSize = samples.count * 2
    var data = Data()
    data.append(contentsOf: Array("RIFF".utf8))
    data.appendLittleEndian(UInt32(36 + dataSize))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(UInt32(24_000))
    data.appendLittleEndian(UInt32(48_000))
    data.appendLittleEndian(UInt16(2))
    data.appendLittleEndian(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    data.appendLittleEndian(UInt32(dataSize))
    data.reserveCapacity(44 + dataSize)
    for sample in samples {
      let clamped = min(1, max(-1, sample))
      let value = Int16(clamped * 32_767)
      data.appendLittleEndian(UInt16(bitPattern: value))
    }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

private final class SynthesisBuffer {
  var samples: [Float] = []
}

private func phononFrame(
  _ pcm: UnsafePointer<Float>?,
  _ count: Int,
  _ user: UnsafeMutableRawPointer?
) -> Bool {
  guard let pcm, let user else { return false }
  let buffer = Unmanaged<SynthesisBuffer>.fromOpaque(user).takeUnretainedValue()
  buffer.samples.append(contentsOf: UnsafeBufferPointer(start: pcm, count: count))
  return true
}

private extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }
}
