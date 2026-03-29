import Foundation

/// Writes latest provider usage data to ~/.tokenpulse/raw_usage.json
/// for consumption by external tools (bash scripts, other apps, etc.).
enum UsageExporter {

    private static let directory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tokenpulse", isDirectory: true)
    }()

    static let fileURL: URL = directory.appendingPathComponent("raw_usage.json")

    struct ExportPayload: Encodable {
        let updatedAt: Date
        let providers: [String: ProviderPayload]
    }

    struct ProviderPayload: Encodable {
        let displayName: String
        let status: String
        let error: String?
        let fiveHour: WindowUsage?
        let sevenDay: WindowUsage?
        let extras: [String: String]?
        let fetchedAt: Date?
    }

    static func write(entries: [ProviderEntry]) {
        var providers: [String: ProviderPayload] = [:]
        for entry in entries {
            let payload: ProviderPayload
            switch entry.status {
            case .ready(let data):
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: "ready",
                    error: nil,
                    fiveHour: data.fiveHour,
                    sevenDay: data.sevenDay,
                    extras: data.extras.isEmpty ? nil : data.extras,
                    fetchedAt: data.fetchedAt
                )
            case .error(let msg):
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: "error",
                    error: msg,
                    fiveHour: nil,
                    sevenDay: nil,
                    extras: nil,
                    fetchedAt: nil
                )
            case .loading:
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: "loading",
                    error: nil,
                    fiveHour: nil,
                    sevenDay: nil,
                    extras: nil,
                    fetchedAt: nil
                )
            case .idle:
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: "idle",
                    error: nil,
                    fiveHour: nil,
                    sevenDay: nil,
                    extras: nil,
                    fetchedAt: nil
                )
            }
            providers[entry.id] = payload
        }

        let export = ExportPayload(updatedAt: .now, providers: providers)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(export)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort — don't crash the app for an export failure
        }
    }
}
