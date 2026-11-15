import Foundation
import CoreML
import SupertonicCore

#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Only the new engine uses this bridge; existing native plugins are unchanged.
@MainActor
final class RelaySupertonic {
  static let shared = RelaySupertonic()
  private var manager: Supertonic3Manager?
  private var directory: URL?
  private var styles: [String: Supertonic3VoiceStyle] = [:]
  private var work: Task<Void, Never>?
  #if os(macOS)
  private var benchmarkActivity: NSObjectProtocol?
  #endif

  func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "relay_reader/supertonic3", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(FlutterError(code: "unavailable", message: "Supertonic is unavailable", details: nil)); return }
      #if os(macOS)
      // This opt-in harness has no audio playback to inhibit App Nap.
      // Apply the same process activity to every engine in the comparison.
      if call.method == "beginBenchmark" {
        if self.benchmarkActivity == nil {
          self.benchmarkActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "User-requested narration benchmark")
        }
        result(nil); return
      }
      if call.method == "endBenchmark" {
        if let activity = self.benchmarkActivity { ProcessInfo.processInfo.endActivity(activity) }
        self.benchmarkActivity = nil; result(nil); return
      }
      #endif
      if call.method == "cancel" { self.work?.cancel(); result(nil); return }
      guard self.work == nil else { result(FlutterError(code: "busy", message: "Supertonic is preparing audio", details: nil)); return }
      self.work = Task {
        defer { self.work = nil }
        do {
          switch call.method {
          case "verify":
            guard let args = call.arguments as? [String: Any], let path = args["path"] as? String,
              let files = args["files"] as? [[String: Any]] else { throw Supertonic3Error.notInitialized }
            let assets = try files.map { file -> ModelAsset in
              guard let path = file["path"] as? String, let bytes = file["bytes"] as? Int,
                let hash = file["sha256"] as? String else { throw Supertonic3Error.notInitialized }
              return ModelAsset(path: path, bytes: Int64(bytes), sha256: hash)
            }
            result(try await ModelAssetVerification.verify(directory: URL(fileURLWithPath: path), files: assets))
          case "load":
            let started = Date()
            guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
              throw Supertonic3Error.notInitialized
            }
            if self.directory?.path != path || self.manager == nil {
              await self.manager?.cleanup()
              self.manager = nil
              self.styles.removeAll()
              #if targetEnvironment(simulator)
              let units: MLComputeUnits = .cpuOnly
              #else
              let units: MLComputeUnits = .cpuAndNeuralEngine
              #endif
              let manager = Supertonic3Manager(directory: URL(fileURLWithPath: path),
                computeUnits: units, vectorEstimator: .aneBucketed(.int4))
              try await manager.initialize()
              try Task.checkCancellation()
              self.manager = manager
              self.directory = URL(fileURLWithPath: path)
            }
            result(["nativeMs": Date().timeIntervalSince(started) * 1000,
              "modelsMs": await self.manager?.loadTimings() ?? [:]])
          case "synthesize":
            let started = Date()
            guard let args = call.arguments as? [String: Any],
              let text = args["text"] as? String, let voice = args["voice"] as? String,
              let language = args["language"] as? String,
              let manager = self.manager, let directory = self.directory,
              Supertonic3Voice(name: voice) != nil else { throw Supertonic3Error.notInitialized }
            if self.styles[voice] == nil {
              self.styles[voice] = try Supertonic3VoiceStyle.load(from: directory.appendingPathComponent("voice_styles/\(voice).json"))
            }
            let audio = try await manager.synthesize(text: text, language: language, style: self.styles[voice]!,
              totalSteps: 8, speed: 1, silenceDuration: 0.05)
            try Task.checkCancellation()
            let data = audio.samples.withUnsafeBytes { Data($0) }
            result(["samples": FlutterStandardTypedData(float32: data), "sampleRate": 44100,
              "nativeMs": Date().timeIntervalSince(started) * 1000,
              "modelsMs": await manager.loadTimings()])
          case "unload":
            await self.manager?.cleanup()
            self.manager = nil; self.directory = nil; self.styles.removeAll()
            result(nil)
          default: result(FlutterMethodNotImplemented)
          }
        } catch {
          result(FlutterError(code: "supertonic_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }
}
