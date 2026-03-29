import Foundation

@MainActor
@Observable
final class ConfigService {
    static let shared = ConfigService()

    var launchAtLogin: Bool {
        didSet { save() }
    }

    var pollInterval: TimeInterval {
        didSet { save() }
    }

    private init() {
        let config = Self.load()
        self.launchAtLogin = config.launchAtLogin
        self.pollInterval = config.pollInterval
    }

    // MARK: - Persistence

    private static let directory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".tokenpulse", isDirectory: true)
    }()

    private static let fileURL = directory.appendingPathComponent("config.json")

    private struct ConfigFile: Codable {
        var launchAtLogin: Bool = false
        var pollInterval: TimeInterval = ProviderConfig.defaultPollInterval
    }

    private static func load() -> ConfigFile {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(ConfigFile.self, from: data) else {
            return ConfigFile()
        }
        return config
    }

    private func save() {
        let config = ConfigFile(launchAtLogin: launchAtLogin, pollInterval: pollInterval)
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
