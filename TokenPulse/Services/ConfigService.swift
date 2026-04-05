import Foundation

@MainActor
@Observable
final class ConfigService {
    static let shared = ConfigService()

    /// Current on-disk schema version. Bump when adding fields that need migration.
    private static let currentConfigVersion = 1

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
    }

    private struct LoadResult {
        let config: ResolvedConfig
        let migrated: Bool
    }

    private struct ResolvedConfig {
        var launchAtLogin: Bool
        var pollInterval: TimeInterval
        var enabledProviders: [String: Bool]
    }

    private static func load() -> LoadResult {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            // No file or unreadable — return factory defaults.
            return LoadResult(
                config: ResolvedConfig(
                    launchAtLogin: false,
                    pollInterval: ProviderConfig.defaultPollInterval,
                    enabledProviders: factoryEnabledProviders
                ),
                migrated: true
            )
        }

        let needsMigration = (file.configVersion ?? 0) < currentConfigVersion
        let resolvedProviders = file.enabledProviders ?? factoryEnabledProviders

        return LoadResult(
            config: ResolvedConfig(
                launchAtLogin: file.launchAtLogin,
                pollInterval: file.pollInterval,
                enabledProviders: resolvedProviders
            ),
            migrated: needsMigration
        )
    }

    private func save() {
        let config = ConfigFile(
            configVersion: Self.currentConfigVersion,
            launchAtLogin: launchAtLogin,
            pollInterval: pollInterval,
            enabledProviders: enabledProviders
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
