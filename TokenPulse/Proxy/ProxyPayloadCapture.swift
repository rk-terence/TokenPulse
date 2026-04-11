import Foundation

/// Captures proxy request payloads to disk for debugging.
/// Each payload is zlib-compressed and written to `~/.tokenpulse/proxy_payloads/`.
///
/// This is an actor (not `@MainActor`) — all file I/O happens off the main thread.
actor ProxyPayloadCapture {

    private var sequenceCounter: UInt64 = 0

    private static let directory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tokenpulse", isDirectory: true)
            .appendingPathComponent("proxy_payloads", isDirectory: true)
    }()

    /// Capture a request payload. The file is named `{timestamp}_{sessionPrefix}_{seq}.json.zz`.
    func capture(requestBody: Data, sessionID: String) {
        let prefix = String(sessionID.prefix(8))
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")  // Filesystem-safe
        sequenceCounter += 1
        let seq = sequenceCounter
        let filename = "\(timestamp)_\(prefix)_\(seq).json.zz"
        let fileURL = Self.directory.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let compressed = try zlibCompress(requestBody)
            try compressed.write(to: fileURL, options: .atomic)
        } catch {
            ProxyLogger.log("PayloadCapture: failed to write \(filename): \(error)")
        }
    }

    /// Compress data using Apple's zlib compression via NSData.
    /// Available on macOS 10.15+; TokenPulse targets macOS 14+.
    private func zlibCompress(_ data: Data) throws -> Data {
        let nsData = data as NSData
        guard let compressed = try? nsData.compressed(using: .zlib) else {
            throw PayloadCaptureError.compressionFailed
        }
        return compressed as Data
    }
}

private enum PayloadCaptureError: Error {
    case compressionFailed
}
