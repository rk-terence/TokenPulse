import Foundation

struct WindowUsage: Codable, Sendable {
    let utilization: Double              // 0.0–100.0 percentage
    let resetsAt: Date?                  // nil if unknown
}

struct UsageData: Codable, Sendable {
    let fiveHour: WindowUsage?           // Primary quota window
    let sevenDay: WindowUsage?           // Secondary quota window
    let extras: [String: String]         // Provider-specific (Opus quota, Flows, etc.)
    let fetchedAt: Date

    var primaryWindowLabel: String {
        extras["primaryWindowLabel"] ?? "5h"
    }

    var secondaryWindowLabel: String {
        extras["secondaryWindowLabel"] ?? "7d"
    }
}
