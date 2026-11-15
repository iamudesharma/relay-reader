// Adapted from FluidAudio d653a34a620c013febd7530427b4963ae18064b2 (Apache-2.0).
#if TTS
@preconcurrency import CoreML
import Foundation

/// Actor-based store for the four Supertonic-3 CoreML models plus the two
/// companion config files (`tts.json`, `unicode_indexer.json`).
///
/// The four stages are:
///   1. `text_encoder`        — text IDs + style → text embedding
///   2. `duration_predictor`  — text IDs + style → per-utterance duration
///   3. `vector_estimator`    — denoising loop input (called N times)
///   4. `vocoder`             — final latent → 44.1 kHz waveform
///
/// All four are intentionally loaded with `.cpuAndNeuralEngine` by default —
/// the converted graphs are FP16 and small enough to fit in ANE working
/// memory. Callers can override at init time (`.cpuOnly` is recommended for
/// Intel Macs and for the smoke tests).
public actor Supertonic3ModelStore {

    private let logger = SupertonicLogger(category: "Supertonic3ModelStore")

    private let directory: URL?
    private let computeUnits: MLComputeUnits
    private let veOption: Supertonic3VectorEstimator

    private var repoDirectory: URL?
    private var textEncoderModel: MLModel?
    private var durationPredictorModel: MLModel?
    private var vocoderModel: MLModel?

    /// Single VectorEstimator for the non-bucketed (`.fp16Dynamic` / `.dynamic`)
    /// modes. `nil` in bucketed mode, where models are loaded lazily per bucket.
    private var vectorEstimatorModel: MLModel?
    /// Lazily-loaded fixed-length VectorEstimators keyed by latent bucket length
    /// (used only in `.aneBucketed` mode).
    private var bucketModels: [Int: MLModel] = [:]

    private(set) var config: Supertonic3Config = .defaults
    public private(set) var loadTimingsMs: [String: Double] = [:]

    public init(
        directory: URL? = nil,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        vectorEstimator: Supertonic3VectorEstimator = .default
    ) {
        self.directory = directory
        self.computeUnits = computeUnits
        self.veOption = vectorEstimator
    }

    /// Compute units the VectorEstimator stage should use. Dynamic-shape builds
    /// cannot use the ANE (CoreML rejects data-dependent shapes), so they are
    /// pinned to CPU/GPU; bucketed builds target the ANE.
    private var veComputeUnits: MLComputeUnits {
        // An explicit .cpuOnly request always wins (it already excludes the ANE,
        // so no override is needed). Otherwise dynamic shapes avoid the ANE
        // (Core ML rejects them) and bucketed builds target it.
        if computeUnits == .cpuOnly { return .cpuOnly }
        switch veOption {
        case .fp16Dynamic: return computeUnits  // preserve historical behavior
        case .dynamic: return .cpuAndGPU
        case .aneBucketed: return .cpuAndNeuralEngine
        }
    }

    // MARK: - Public API

    /// Download (if missing) the four `.mlmodelc` bundles + `tts.json` +
    /// `unicode_indexer.json` and load the CoreML stages.
    public func loadIfNeeded() async throws {
        if textEncoderModel != nil { return }

        guard let repoDir = directory else { throw Supertonic3Error.notInitialized }
        self.repoDirectory = repoDir

        // tts.json — optional override of the compile-time defaults. If parsing
        // fails we keep the defaults and warn so callers can debug.
        let configURL = repoDir.appendingPathComponent(SupertonicModelFiles.configFile)
        if FileManager.default.fileExists(atPath: configURL.path) {
            do {
                let data = try Data(contentsOf: configURL)
                self.config = try JSONDecoder().decode(Supertonic3Config.self, from: data)
            } catch {
                logger.warning(
                    "Failed to decode tts.json (\(error)); using compile-time defaults")
            }
        }

        logger.info("Loading Supertonic-3 CoreML models from \(repoDir.path)…")
        let loadStart = Date()

        // Independent stages load concurrently. Keep the published CPU/ANE
        // routing and preload only the common L128 bucket; larger ones stay lazy.
        async let text = Self.loadAsync(repoDir, SupertonicModelFiles.textEncoderFile, computeUnits)
        async let duration = Self.loadAsync(repoDir, SupertonicModelFiles.durationPredictorFile, computeUnits)
        async let vocoder = Self.loadAsync(repoDir, SupertonicModelFiles.vocoderFile, computeUnits)
        let vectorName = SupertonicModelFiles.vectorEstimatorFile(
            precisionSuffix: veOption.precisionSuffix, bucket: veOption.isBucketed ? 128 : nil)
        async let vector = Self.loadAsync(repoDir, vectorName, veComputeUnits)
        let loaded = try await (text, duration, vocoder, vector)
        try Task.checkCancellation()
        textEncoderModel = loaded.0.model
        durationPredictorModel = loaded.1.model
        vocoderModel = loaded.2.model
        if veOption.isBucketed { bucketModels[128] = loaded.3.model }
        else { vectorEstimatorModel = loaded.3.model }
        loadTimingsMs = [
            SupertonicModelFiles.textEncoderFile: loaded.0.ms,
            SupertonicModelFiles.durationPredictorFile: loaded.1.ms,
            SupertonicModelFiles.vocoderFile: loaded.2.ms,
            vectorName: loaded.3.ms,
        ]

        let elapsed = Date().timeIntervalSince(loadStart)
        logger.info(
            "Supertonic-3 models loaded in \(String(format: "%.2f", elapsed))s")
    }

    // MARK: - Accessors

    public func textEncoder() throws -> MLModel { try unwrap(textEncoderModel, name: "text_encoder") }
    public func durationPredictor() throws -> MLModel {
        try unwrap(durationPredictorModel, name: "duration_predictor")
    }
    /// Resolve the VectorEstimator for a chunk of `latentLength` TTL slots.
    ///
    /// Returns the model plus the latent length the caller must feed it: in
    /// dynamic modes that equals `latentLength` (no padding); in bucketed mode
    /// it is the smallest published bucket ≥ `latentLength`, and the caller pads
    /// the latent/mask up to that length. Bucket models are loaded lazily and
    /// cached.
    public func vectorEstimator(forLatentLength latentLength: Int) throws -> (model: MLModel, paddedLength: Int) {
        guard veOption.isBucketed else {
            return (try unwrap(vectorEstimatorModel, name: "vector_estimator"), latentLength)
        }
        guard let bucket = SupertonicModelFiles.aneBuckets.first(where: { $0 >= latentLength })
        else {
            throw Supertonic3Error.inferenceFailed(
                stage: "vector_estimator",
                underlying:
                    "latent length \(latentLength) exceeds largest ANE bucket "
                    + "\(SupertonicModelFiles.aneBuckets.last ?? 0); use a dynamic VectorEstimator")
        }
        if let cached = bucketModels[bucket] { return (cached, bucket) }

        guard let repoDir = repoDirectory else { throw Supertonic3Error.notInitialized }
        let veCfg = MLModelConfiguration()
        veCfg.computeUnits = veComputeUnits
        let model = try loadModel(
            repoDir: repoDir,
            fileName: SupertonicModelFiles.vectorEstimatorFile(
                precisionSuffix: veOption.precisionSuffix, bucket: bucket),
            config: veCfg)
        bucketModels[bucket] = model
        return (model, bucket)
    }
    public func vocoder() throws -> MLModel { try unwrap(vocoderModel, name: "vocoder") }

    public func repoDir() throws -> URL {
        guard let dir = repoDirectory else { throw Supertonic3Error.notInitialized }
        return dir
    }

    /// Path to `unicode_indexer.json` after `loadIfNeeded()` has succeeded.
    public func unicodeIndexerURL() throws -> URL {
        try repoDir().appendingPathComponent(SupertonicModelFiles.unicodeIndexerFile)
    }

    public func unload() {
        textEncoderModel = nil
        durationPredictorModel = nil
        vectorEstimatorModel = nil
        bucketModels.removeAll()
        vocoderModel = nil
    }

    // MARK: - Helpers

    private func unwrap(_ model: MLModel?, name: String) throws -> MLModel {
        guard let model else { throw Supertonic3Error.notInitialized }
        return model
    }

    private static func loadAsync(_ directory: URL, _ name: String, _ units: MLComputeUnits)
        async throws -> (model: MLModel, ms: Double) {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Supertonic3Error.modelFileNotFound(name)
        }
        let config = MLModelConfiguration()
        config.computeUnits = units
        let started = Date()
        do {
            let model = try await MLModel.load(contentsOf: url, configuration: config)
            try Task.checkCancellation()
            return (model, Date().timeIntervalSince(started) * 1000)
        } catch is CancellationError { throw CancellationError() }
        catch { throw Supertonic3Error.corruptedModel(name, underlying: "\(error)") }
    }

    private func loadModel(
        repoDir: URL, fileName: String, config: MLModelConfiguration
    ) throws -> MLModel {
        let modelURL = repoDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw Supertonic3Error.modelFileNotFound(fileName)
        }
        do {
            let started = Date()
            let model = try MLModel(contentsOf: modelURL, configuration: config)
            loadTimingsMs[fileName] = Date().timeIntervalSince(started) * 1000
            logger.info("Loaded \(fileName)")
            return model
        } catch {
            throw Supertonic3Error.corruptedModel(fileName, underlying: "\(error)")
        }
    }
}
#endif
