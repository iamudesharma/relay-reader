import Foundation
import os

struct SupertonicLogger {
  private let logger: Logger
  init(category: String) { logger = Logger(subsystem: "com.relay.supertonic", category: category) }
  func info(_ message: String) { logger.info("\(message, privacy: .public)") }
  func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
}

enum SupertonicModelFiles {
  static let configFile = "tts.json"
  static let unicodeIndexerFile = "unicode_indexer.json"
  static let textEncoderFile = "TextEncoder_v2.mlmodelc"
  static let durationPredictorFile = "DurationPredictor_v2.mlmodelc"
  static let vocoderFile = "Vocoder.mlmodelc"
  static let aneBuckets = [128, 256, 512]
  static func vectorEstimatorFile(precisionSuffix: String?, bucket: Int?) -> String {
    if let bucket, let suffix = precisionSuffix {
      return "VectorEstimatorVariants/VectorEstimator_v2_L\(bucket)_\(suffix).mlmodelc"
    }
    if let suffix = precisionSuffix { return "VectorEstimatorVariants/VectorEstimator_v2_\(suffix).mlmodelc" }
    return "VectorEstimator_v2.mlmodelc"
  }
}
