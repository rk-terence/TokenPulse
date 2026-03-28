import Foundation

struct WindowUsage: Codable, Sendable {
    let utilization: Double              // 0.0–100.0 percentage
    let resetsAt: Date?                  // nil if unknown
}

struct UsageData: Codable, Sendable {
    let fiveHour: WindowUsage?           // 5-hour rolling window
    let sevenDay: WindowUsage?           // Weekly quota
    let extras: [String: String]         // Provider-specific (Opus quota, Flows, etc.)
    let fetchedAt: Date
}
