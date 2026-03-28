import SwiftUI

protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var shortLabel: String { get }       // Single char for menu bar: "C", "Z"
    var brandColor: Color { get }
    func fetchUsage() async throws -> UsageData
    func isConfigured() -> Bool
}
