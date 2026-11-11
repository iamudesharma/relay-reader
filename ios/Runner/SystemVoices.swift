import AVFoundation
import Flutter

/// Native bridge for Apple system voices. The Flutter side uses this to list
/// installed English voices, render speech to a CAF file for the existing
/// just_audio queue, and play short voice previews.
final class RelaySystemVoices: NSObject, AVSpeechSynthesizerDelegate {
  static let shared = RelaySystemVoices()
  static let channelName = "relay_reader/system_voices"

  private let synthesizer = AVSpeechSynthesizer()
  private let previewSynthesizer = AVSpeechSynthesizer()
  private let lock = NSLock()
  private var output: AVAudioFile?
  private var outputURL: URL?
  private var completion: FlutterResult?
  private var previewCompletion: FlutterResult?
  private var finished = true

  override init() {
    super.init()
    previewSynthesizer.delegate = self
  }

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
            message: "System voices are unavailable.",
            details: nil
          )
        )
        return
      }
      switch call.method {
      case "list":
        result(self.voices())
      case "synthesize":
        self.synthesize(call.arguments, result: result)
      case "preview":
        self.preview(call.arguments, result: result)
      case "stopPreview":
        self.stopPreview()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func voices() -> [[String: Any]] {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language.hasPrefix("en") }
      .map { voice in
        [
          "identifier": voice.identifier,
          "name": voice.name,
          "locale": voice.language,
          "quality": voice.quality.rawValue,
        ]
      }
      .sorted { lhs, rhs in
        let leftQuality = lhs["quality"] as? Int ?? 0
        let rightQuality = rhs["quality"] as? Int ?? 0
        if leftQuality != rightQuality { return leftQuality > rightQuality }
        let leftName = lhs["name"] as? String ?? ""
        let rightName = rhs["name"] as? String ?? ""
        return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
      }
  }

  private func makeUtterance(_ args: [String: Any]) -> AVSpeechUtterance? {
    guard let text = args["text"] as? String, !text.isEmpty else { return nil }
    let utterance = AVSpeechUtterance(string: text)
    if let identifier = args["identifier"] as? String,
       !identifier.isEmpty,
       let voice = AVSpeechSynthesisVoice(identifier: identifier) {
      utterance.voice = voice
    } else {
      utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
    }
    let rate = (args["rate"] as? Double) ?? 0.5
    let volume = (args["volume"] as? Double) ?? 1
    let pitch = (args["pitch"] as? Double) ?? 1
    utterance.rate = Float(min(max(rate, 0.1), 1.0))
    utterance.volume = Float(min(max(volume, 0), 1))
    utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2))
    utterance.preUtteranceDelay = 0
    utterance.postUtteranceDelay = 0
    return utterance
  }

  private func activateSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .spokenAudio)
    try? session.setActive(true)
  }

  private func preview(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let utterance = makeUtterance(args) else {
      result(
        FlutterError(
          code: "bad_arguments",
          message: "A preview needs text and a voice.",
          details: nil
        )
      )
      return
    }
    stopPreview()
    previewCompletion = result
    activateSession()
    previewSynthesizer.speak(utterance)
  }

  private func stopPreview() {
    previewSynthesizer.stopSpeaking(at: .immediate)
    finishPreview(success: false)
  }

  private func finishPreview(success: Bool) {
    let result = previewCompletion
    previewCompletion = nil
    result?(success)
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didFinish utterance: AVSpeechUtterance
  ) {
    if synthesizer === previewSynthesizer { finishPreview(success: true) }
  }

  func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer,
    didCancel utterance: AVSpeechUtterance
  ) {
    if synthesizer === previewSynthesizer { finishPreview(success: false) }
  }

  private func synthesize(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let path = args["path"] as? String,
          let utterance = makeUtterance(args) else {
      result(
        FlutterError(
          code: "bad_arguments",
          message: "Speech needs text and an output path.",
          details: nil
        )
      )
      return
    }

    lock.lock()
    if !finished {
      lock.unlock()
      result(
        FlutterError(
          code: "busy",
          message: "Another passage is still being prepared.",
          details: nil
        )
      )
      return
    }
    finished = false
    output = nil
    outputURL = URL(fileURLWithPath: path)
    completion = result
    lock.unlock()

    activateSession()
    if let url = outputURL {
      try? FileManager.default.removeItem(at: url)
    }
    synthesizer.write(utterance) { [weak self] buffer in
      guard let self else { return }
      guard let pcm = buffer as? AVAudioPCMBuffer else {
        self.finishSpeech(success: false)
        return
      }
      if pcm.frameLength == 0 {
        self.finishSpeech(success: true)
        return
      }

      self.lock.lock()
      if self.finished {
        self.lock.unlock()
        return
      }
      do {
        if self.output == nil {
          guard let url = self.outputURL else {
            self.lock.unlock()
            self.finishSpeech(success: false)
            return
          }
          self.output = try AVAudioFile(
            forWriting: url,
            settings: pcm.format.settings
          )
        }
        try self.output?.write(from: pcm)
        self.lock.unlock()
      } catch {
        self.lock.unlock()
        self.finishSpeech(success: false)
      }
    }
  }

  private func finishSpeech(success: Bool) {
    lock.lock()
    if finished {
      lock.unlock()
      return
    }
    finished = true
    let result = completion
    completion = nil
    output = nil
    let url = outputURL
    outputURL = nil
    lock.unlock()

    if !success, let url {
      try? FileManager.default.removeItem(at: url)
    }
    DispatchQueue.main.async {
      result?(success)
    }
  }
}
