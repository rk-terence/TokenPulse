import Foundation

struct ProviderConfig: Codable, Sendable, Identifiable {
    let id: String
    var enabled: Bool
    var pollInterval: TimeInterval

    static let defaultPollInterval: TimeInterval = 120
    static let minimumPollInterval: TimeInterval = 60
}
