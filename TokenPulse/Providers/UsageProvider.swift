import SwiftUI

/// Describes how a fetch failure should be treated by the system.
enum FailureDisposition: Sendable {
    /// Provider is not configured (missing key/credentials). Don't retry.
    case unconfigured
    /// Temporary problem — show stale data, retry on next poll.
    case transient(String)
    /// Auth/credential issue — show stale data, surface auth guidance.
    case auth(String)
    /// Permanent/unknown error — show error state.
    case persistent(String)
}

protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var shortLabel: String { get }       // Single char for menu bar: "C", "Z"
    var brandColor: Color { get }
    func fetchUsage() async throws -> UsageData
    func isConfigured() -> Bool
    func classifyError(_ error: Error) -> FailureDisposition
}
