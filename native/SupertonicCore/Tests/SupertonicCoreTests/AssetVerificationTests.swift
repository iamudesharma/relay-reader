import Foundation
import XCTest
@testable import SupertonicCore

final class AssetVerificationTests: XCTestCase {
  func testSHA256DetectsSameLengthCorruptionAndMissingFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("model.bin")
    let asset = ModelAsset(path: "model.bin", bytes: 3,
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    try Data("abc".utf8).write(to: file)
    let valid = try await ModelAssetVerification.verify(directory: directory, files: [asset])
    XCTAssertTrue(valid)
    try Data("abd".utf8).write(to: file)
    let corrupted = try await ModelAssetVerification.verify(directory: directory, files: [asset])
    XCTAssertFalse(corrupted)
    try FileManager.default.removeItem(at: file)
    do {
      _ = try await ModelAssetVerification.verify(directory: directory, files: [asset])
      XCTFail("A missing file must not verify")
    } catch { }
  }
}
