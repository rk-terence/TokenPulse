import Foundation

@MainActor
@Observable
final class ConfigService {
    static let shared = ConfigService()

    /// Current on-disk schema version. Bump when adding fields that need migration.
    private static let currentConfigVersion = 6
    private static let defaultAnthropicUpstreamURL = "https://zenmux.ai/api/anthropic"
    private static let defaultOpenAIUpstreamURL = "https://api.openai.com"

    /// Factory defaults for provider enablement.
    static let factoryEnabledProviders: [String: Bool] = ["claude": false, "codex": false, "zenmux": true]

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

    var keepaliveEnabled: Bool {
        didSet { save() }
    }

    var keepaliveIntervalSeconds: Int {
        didSet { save() }
    }

    var proxyInactivityTimeoutSeconds: Int {
        didSet { save() }
    }

    var saveProxyEventLog: Bool {
        didSet { save() }
    }

    var saveProxyPayloads: Bool {
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
        self.keepaliveEnabled = loaded.config.keepaliveEnabled
        self.keepaliveIntervalSeconds = loaded.config.keepaliveIntervalSeconds
        self.proxyInactivityTimeoutSeconds = loaded.config.proxyInactivityTimeoutSeconds
        self.saveProxyEventLog = loaded.config.saveProxyEventLog
        self.saveProxyPayloads = loaded.config.saveProxyPayloads

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
        var keepaliveEnabled: Bool?
        var keepaliveIntervalSeconds: Int?
        var proxyInactivityTimeoutSeconds: Int?
        var saveProxyEventLog: Bool?
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
        var keepaliveEnabled: Bool
        var keepaliveIntervalSeconds: Int
        var proxyInactivityTimeoutSeconds: Int
        var saveProxyEventLog: Bool
        var saveProxyPayloads: Bool
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
                    keepaliveEnabled: false,
                    keepaliveIntervalSeconds: 240,
                    proxyInactivityTimeoutSeconds: 900,
                    saveProxyEventLog: true,
                    saveProxyPayloads: false
                ),
                migrated: true
            )
        }

        let needsMigration = (file.configVersion ?? 0) < currentConfigVersion
        let resolvedProviders = file.enabledProviders ?? factoryEnabledProviders
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
                keepaliveEnabled: file.keepaliveEnabled ?? false,
                keepaliveIntervalSeconds: file.keepaliveIntervalSeconds ?? 240,
                proxyInactivityTimeoutSeconds: file.proxyInactivityTimeoutSeconds ?? 900,
                saveProxyEventLog: file.saveProxyEventLog ?? true,
                saveProxyPayloads: file.saveProxyPayloads ?? false
            ),
            migrated: needsMigration
        )
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
            keepaliveEnabled: keepaliveEnabled,
            keepaliveIntervalSeconds: keepaliveIntervalSeconds,
            proxyInactivityTimeoutSeconds: proxyInactivityTimeoutSeconds,
            saveProxyEventLog: saveProxyEventLog,
            saveProxyPayloads: saveProxyPayloads
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
