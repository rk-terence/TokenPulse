import Foundation

@MainActor
@Observable
final class ConfigService {
    static let shared = ConfigService()

    /// Current on-disk schema version. Bump when adding fields that need migration.
    private static let currentConfigVersion = 8
    private static let defaultAnthropicUpstreamURL = "https://zenmux.ai/api/anthropic"
    private static let defaultOpenAIUpstreamURL = "https://api.openai.com"

    /// Factory defaults for provider enablement.
    static let factoryEnabledProviders: [String: Bool] = ["codex": false, "zenmux": true]
    private static let supportedProviderIDs = Set(factoryEnabledProviders.keys)

    var launchAtLogin: Bool {
        didSet { save() }
    }

    var pollInterval: TimeInterval {
        didSet { save() }
    }

    private(set) var enabledProviders: [String: Bool] {
        didSet { save() }
    }

    var proxyEnabled: Bool {
        didSet { save() }
    }

    var anthropicUpstreamURL: String {
        didSet { save() }
    }

    var openAIUpstreamURL: String {
        didSet { save() }
    }

    var proxyPort: Int {
        didSet { save() }
    }

    /// Single on/off toggle for the unified proxy event log (metadata + deduplicated payloads).
    /// When disabled, no SQLite database is opened and nothing is written to disk.
    var saveProxyEventLog: Bool {
        didSet { save() }
    }

    func isProviderEnabled(_ id: String) -> Bool {
        enabledProviders[id] ?? false
    }

    func setProviderEnabled(_ id: String, _ enabled: Bool) {
        enabledProviders[id] = enabled
    }

    private init() {
        let loaded = Self.load()
        self.launchAtLogin = loaded.config.launchAtLogin
        self.pollInterval = loaded.config.pollInterval
        self.enabledProviders = loaded.config.enabledProviders
        self.proxyEnabled = loaded.config.proxyEnabled
        self.anthropicUpstreamURL = loaded.config.anthropicUpstreamURL
        self.openAIUpstreamURL = loaded.config.openAIUpstreamURL
        self.proxyPort = loaded.config.proxyPort
        self.saveProxyEventLog = loaded.config.saveProxyEventLog

        // Persist migrated config if the on-disk version was outdated.
        if loaded.migrated {
            save()
        }
    }

    // MARK: - Persistence

    private static let directory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tokenpulse", isDirectory: true)
    }()

    private static let fileURL = directory.appendingPathComponent("config.json")

    private struct ConfigFile: Codable {
        var configVersion: Int?
        var launchAtLogin: Bool = false
        var pollInterval: TimeInterval = ProviderConfig.defaultPollInterval
        var enabledProviders: [String: Bool]?
        var proxyEnabled: Bool?
        var anthropicUpstreamURL: String?
        var openAIUpstreamURL: String?
        var proxyUpstreamURL: String?
        var proxyPort: Int?
        var saveProxyEventLog: Bool?
        // Retained for migration only — no longer written.
        var keepaliveEnabled: Bool?
        var keepaliveIntervalSeconds: Int?
        var proxyInactivityTimeoutSeconds: Int?
        var saveProxyPayloads: Bool?
    }

    private struct LoadResult {
        let config: ResolvedConfig
        let migrated: Bool
    }

    private struct ResolvedConfig {
        var launchAtLogin: Bool
        var pollInterval: TimeInterval
        var enabledProviders: [String: Bool]
        var proxyEnabled: Bool
        var anthropicUpstreamURL: String
        var openAIUpstreamURL: String
        var proxyPort: Int
        var saveProxyEventLog: Bool
    }

    private static func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            // No file or unreadable — return factory defaults.
            return LoadResult(
                config: ResolvedConfig(
                    launchAtLogin: false,
                    pollInterval: ProviderConfig.defaultPollInterval,
                    enabledProviders: factoryEnabledProviders,
                    proxyEnabled: false,
                    anthropicUpstreamURL: defaultAnthropicUpstreamURL,
                    openAIUpstreamURL: defaultOpenAIUpstreamURL,
                    proxyPort: 8080,
                    saveProxyEventLog: true
                ),
                migrated: true
            )
        }

        let needsMigration = (file.configVersion ?? 0) < currentConfigVersion
        let resolvedProviders = resolvedEnabledProviders(file.enabledProviders)
        let migratedAnthropicUpstreamURL = file.anthropicUpstreamURL
            ?? file.proxyUpstreamURL
            ?? defaultAnthropicUpstreamURL

        return LoadResult(
            config: ResolvedConfig(
                launchAtLogin: file.launchAtLogin,
                pollInterval: file.pollInterval,
                enabledProviders: resolvedProviders,
                proxyEnabled: file.proxyEnabled ?? false,
                anthropicUpstreamURL: migratedAnthropicUpstreamURL,
                openAIUpstreamURL: file.openAIUpstreamURL ?? defaultOpenAIUpstreamURL,
                proxyPort: file.proxyPort ?? 8080,
                saveProxyEventLog: file.saveProxyEventLog ?? true
            ),
            migrated: needsMigration
        )
    }

    private static func resolvedEnabledProviders(_ loaded: [String: Bool]?) -> [String: Bool] {
        var resolved = factoryEnabledProviders
        guard let loaded else { return resolved }

        for (id, enabled) in loaded where supportedProviderIDs.contains(id) {
            resolved[id] = enabled
        }

        return resolved
    }

    private func save() {
        let config = ConfigFile(
            configVersion: Self.currentConfigVersion,
            launchAtLogin: launchAtLogin,
            pollInterval: pollInterval,
            enabledProviders: enabledProviders,
            proxyEnabled: proxyEnabled,
            anthropicUpstreamURL: anthropicUpstreamURL,
            openAIUpstreamURL: openAIUpstreamURL,
            proxyUpstreamURL: nil,
            proxyPort: proxyPort,
            saveProxyEventLog: saveProxyEventLog,
            keepaliveEnabled: nil,
            keepaliveIntervalSeconds: nil,
            proxyInactivityTimeoutSeconds: nil,
            saveProxyPayloads: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let data = try encoder.encode(config)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            // Best-effort — don't crash for a config write failure
        }
    }
}
