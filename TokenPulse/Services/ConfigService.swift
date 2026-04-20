import Foundation

@MainActor
@Observable
final class ConfigService {
    static let shared = ConfigService()

    /// Current on-disk schema version. Bump when adding fields that need migration.
    private static let currentConfigVersion = 10
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

    var upstreamHTTPSProxyEnabled: Bool {
        didSet { save() }
    }

    var useSystemUpstreamProxy: Bool {
        didSet { save() }
    }

    var upstreamHTTPProxyURL: String {
        didSet { save() }
    }

    var upstreamHTTPSProxyURL: String {
        didSet { save() }
    }

    /// Single on/off toggle for the unified proxy event log (metadata + deduplicated payloads).
    /// When disabled, no SQLite database is opened and nothing is written to disk.
    var saveProxyEventLog: Bool {
        didSet { save() }
    }

    var customUpstreamProxySetting: UpstreamHTTPSProxySetting {
        if upstreamHTTPSProxyEnabled {
            let httpProxy: ProxyEndpoint?
            do {
                httpProxy = try ProxyEndpoint.parseOptional(urlString: upstreamHTTPProxyURL)
            } catch {
                return .invalid(String(localized: "HTTP proxy URL: \(error.localizedDescription)"))
            }

            let httpsProxy: ProxyEndpoint?
            do {
                httpsProxy = try ProxyEndpoint.parseOptional(urlString: upstreamHTTPSProxyURL)
            } catch {
                return .invalid(String(localized: "HTTPS proxy URL: \(error.localizedDescription)"))
            }

            return .configured(
                HTTPSProxyConfiguration(
                    httpProxy: httpProxy,
                    httpsProxy: httpsProxy
                )
            )
        }

        return .disabled
    }

    var systemUpstreamProxySetting: UpstreamHTTPSProxySetting {
        if let configuration = HTTPSProxyConfiguration.systemConfiguration() {
            return .configured(configuration)
        }

        return .disabled
    }

    var effectiveUpstreamProxySetting: UpstreamHTTPSProxySetting {
        let customSetting = customUpstreamProxySetting
        if upstreamHTTPSProxyEnabled || customSetting.validationError != nil {
            return customSetting
        }

        if useSystemUpstreamProxy {
            return systemUpstreamProxySetting
        }

        return .disabled
    }

    var customUpstreamProxyValidationError: String? {
        customUpstreamProxySetting.validationError
    }

    var systemUpstreamProxySummary: String? {
        systemUpstreamProxySetting.proxyConfiguration?.summaryDescription
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
        self.upstreamHTTPSProxyEnabled = loaded.config.upstreamHTTPSProxyEnabled
        self.useSystemUpstreamProxy = loaded.config.useSystemUpstreamProxy
        self.upstreamHTTPProxyURL = loaded.config.upstreamHTTPProxyURL
        self.upstreamHTTPSProxyURL = loaded.config.upstreamHTTPSProxyURL
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
        var upstreamHTTPSProxyEnabled: Bool?
        var useSystemUpstreamProxy: Bool?
        var upstreamHTTPProxyURL: String?
        var upstreamHTTPSProxyURL: String?
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
        var upstreamHTTPSProxyEnabled: Bool
        var useSystemUpstreamProxy: Bool
        var upstreamHTTPProxyURL: String
        var upstreamHTTPSProxyURL: String
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
                    upstreamHTTPSProxyEnabled: false,
                    useSystemUpstreamProxy: true,
                    upstreamHTTPProxyURL: "",
                    upstreamHTTPSProxyURL: "",
                    saveProxyEventLog: true
                ),
                migrated: true
            )
        }

        let needsMigration = (file.configVersion ?? 0) < currentConfigVersion
        let resolvedProviders = file.enabledProviders ?? factoryEnabledProviders
        let migratedAnthropicUpstreamURL = file.anthropicUpstreamURL
            ?? file.proxyUpstreamURL
            ?? defaultAnthropicUpstreamURL
        let migratedCustomProxyURL = (file.configVersion ?? 0) < currentConfigVersion
            ? (file.upstreamHTTPProxyURL ?? file.upstreamHTTPSProxyURL ?? "")
            : ""
        let resolvedHTTPProxyURL = file.upstreamHTTPProxyURL
            ?? migratedCustomProxyURL
        let resolvedHTTPSProxyURL = file.upstreamHTTPSProxyURL
            ?? migratedCustomProxyURL

        return LoadResult(
            config: ResolvedConfig(
                launchAtLogin: file.launchAtLogin,
                pollInterval: file.pollInterval,
                enabledProviders: resolvedProviders,
                proxyEnabled: file.proxyEnabled ?? false,
                anthropicUpstreamURL: migratedAnthropicUpstreamURL,
                openAIUpstreamURL: file.openAIUpstreamURL ?? defaultOpenAIUpstreamURL,
                proxyPort: file.proxyPort ?? 8080,
                upstreamHTTPSProxyEnabled: file.upstreamHTTPSProxyEnabled ?? false,
                useSystemUpstreamProxy: file.useSystemUpstreamProxy ?? true,
                upstreamHTTPProxyURL: resolvedHTTPProxyURL,
                upstreamHTTPSProxyURL: resolvedHTTPSProxyURL,
                saveProxyEventLog: file.saveProxyEventLog ?? true
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
            upstreamHTTPSProxyEnabled: upstreamHTTPSProxyEnabled,
            useSystemUpstreamProxy: useSystemUpstreamProxy,
            upstreamHTTPProxyURL: upstreamHTTPProxyURL,
            upstreamHTTPSProxyURL: upstreamHTTPSProxyURL,
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
