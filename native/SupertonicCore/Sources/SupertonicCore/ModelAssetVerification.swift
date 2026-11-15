import CryptoKit
import Foundation

public struct ModelAsset: Sendable {
  public let path: String
  public let bytes: Int64
  public let sha256: String
  public init(path: String, bytes: Int64, sha256: String) {
    self.path = path; self.bytes = bytes; self.sha256 = sha256
  }
}

/// Streaming system SHA-256 keeps full integrity checks off Flutter's UI isolate.
public enum ModelAssetVerification {
  public static func verify(directory: URL, files: [ModelAsset]) async throws -> Bool {
    let task = Task.detached(priority: .userInitiated) {
      for asset in files {
        try Task.checkCancellation()
        guard !asset.path.hasPrefix("/"), !asset.path.contains("\\"),
          !asset.path.split(separator: "/").contains("..") else { return false }
        let url = directory.appendingPathComponent(asset.path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == Int(asset.bytes) else { return false }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
          try Task.checkCancellation()
          hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == asset.sha256 else { return false }
      }
      return true
    }
    return try await withTaskCancellationHandler(operation: { try await task.value },
      onCancel: { task.cancel() })
  }
}
