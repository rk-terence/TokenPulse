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
        let lastAttemptAt: Date?
        let lastSuccessAt: Date?
    }

    static func write(entries: [ProviderEntry]) {
        var providers: [String: ProviderPayload] = [:]
        for entry in entries {
            let payload: ProviderPayload
            switch entry.status {
            case .unconfigured:
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: "unconfigured",
                    error: nil,
                    fiveHour: nil,
                    sevenDay: nil,
                    extras: nil,
                    fetchedAt: nil,
                    lastAttemptAt: entry.lastAttemptAt,
                    lastSuccessAt: entry.lastSuccessAt
                )
            case .pendingFirstLoad:
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: "pending_first_load",
                    error: nil,
                    fiveHour: nil,
                    sevenDay: nil,
                    extras: nil,
                    fetchedAt: nil,
                    lastAttemptAt: entry.lastAttemptAt,
                    lastSuccessAt: entry.lastSuccessAt
                )
            case .refreshing(let lastData, _):
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: "refreshing",
                    error: nil,
                    fiveHour: lastData?.fiveHour,
                    sevenDay: lastData?.sevenDay,
                    extras: lastData?.extras.isEmpty == false ? lastData?.extras : nil,
                    fetchedAt: lastData?.fetchedAt,
                    lastAttemptAt: entry.lastAttemptAt,
                    lastSuccessAt: entry.lastSuccessAt
                )
            case .ready(let data):
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: "ready",
                    error: nil,
                    fiveHour: data.fiveHour,
                    sevenDay: data.sevenDay,
                    extras: data.extras.isEmpty ? nil : data.extras,
                    fetchedAt: data.fetchedAt,
                    lastAttemptAt: entry.lastAttemptAt,
                    lastSuccessAt: entry.lastSuccessAt
                )
            case .stale(let data, let reason, let msg):
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: reason == .auth ? "auth_stale" : "stale",
                    error: msg,
                    fiveHour: data.fiveHour,
                    sevenDay: data.sevenDay,
                    extras: data.extras.isEmpty ? nil : data.extras,
                    fetchedAt: data.fetchedAt,
                    lastAttemptAt: entry.lastAttemptAt,
                    lastSuccessAt: entry.lastSuccessAt
                )
            case .error(let msg):
                payload = ProviderPayload(
                    displayName: entry.displayName,
                    status: "error",
                    error: msg,
                    fiveHour: nil,
                    sevenDay: nil,
                    extras: nil,
                    fetchedAt: nil,
                    lastAttemptAt: entry.lastAttemptAt,
                    lastSuccessAt: entry.lastSuccessAt
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
